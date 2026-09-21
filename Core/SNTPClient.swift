import Foundation
import Network

/// One completed NTP exchange.
struct SNTPSample {
    /// UTC minus host clock, in seconds. Add to a host reading to get UTC.
    let offset: Double
    /// Round-trip delay. Asymmetric path delay is the dominant error in an NTP
    /// measurement and it correlates with total delay, so smaller is better.
    let delay: Double
    let hostTime: Double
}

enum SNTPError: Error {
    case timeout
    case malformed
    case rejected(String)
}

/// Minimal SNTP client (RFC 4330) over UDP port 123.
///
/// T1 and T4 are read from `HostClock` rather than `Date()`, so the offset it
/// produces lands directly in the domain the overlay needs instead of routing
/// through a wall clock that may itself be mid-correction.
enum SNTPClient {

    static let servers = ["time.apple.com", "time.cloudflare.com", "pool.ntp.org"]

    private static let ntpToUnix: Double = 2_208_988_800

    /// Samples every server, then returns the exchange with the smallest
    /// round-trip. Unreachable servers are skipped rather than fatal: one bad
    /// host on a marginal link should not sink the measurement.
    static func measure(samplesPerServer: Int = 4) async -> SNTPSample? {
        var collected: [SNTPSample] = []
        for server in servers {
            for _ in 0..<samplesPerServer {
                if let sample = try? await exchange(server: server) {
                    collected.append(sample)
                }
                // Spaced so we sample independent queue states rather than
                // catching several packets in one burst.
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        return collected.filter { $0.delay <= 0.25 }.min { $0.delay < $1.delay }
    }

    static func exchange(server: String, timeout: TimeInterval = 2.0) async throws -> SNTPSample {
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 123, using: .udp)
        let queue = DispatchQueue(label: "sntp.\(server)")

        return try await withCheckedThrowingContinuation { continuation in
            let once = Resumer(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var packet = Data(count: 48)
                    packet[0] = 0x23  // LI 0, version 4, mode 3 (client)

                    let t1 = HostClock.now()
                    connection.send(content: packet, completion: .contentProcessed { error in
                        if let error {
                            once.fail(error)
                            connection.cancel()
                        }
                    })

                    connection.receiveMessage { data, _, _, error in
                        let t4 = HostClock.now()
                        defer { connection.cancel() }
                        if let error { once.fail(error); return }
                        guard let data, data.count >= 48 else {
                            once.fail(SNTPError.malformed)
                            return
                        }
                        do { once.succeed(try decode(data, t1: t1, t4: t4)) }
                        catch { once.fail(error) }
                    }

                case .failed(let error):
                    once.fail(error)
                    connection.cancel()

                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.fail(SNTPError.timeout)
                connection.cancel()
            }
        }
    }

    private static func decode(_ data: Data, t1: Double, t4: Double) throws -> SNTPSample {
        let bytes = [UInt8](data)

        guard (bytes[0] >> 6) & 0x03 != 3 else { throw SNTPError.rejected("unsynchronized") }
        let stratum = bytes[1]
        guard stratum > 0, stratum < 15 else { throw SNTPError.rejected("stratum \(stratum)") }

        let t2 = unixSeconds(bytes, at: 32)  // server receive
        let t3 = unixSeconds(bytes, at: 40)  // server transmit
        guard t2 > 0, t3 > 0 else { throw SNTPError.malformed }

        return SNTPSample(offset: ((t2 - t1) + (t3 - t4)) / 2,
                          delay: max((t4 - t1) - (t3 - t2), 0),
                          hostTime: t4)
    }

    /// Decodes a 64-bit NTP timestamp (32.32 fixed point, epoch 1900) to Unix seconds.
    private static func unixSeconds(_ bytes: [UInt8], at index: Int) -> Double {
        var seconds: UInt32 = 0
        var fraction: UInt32 = 0
        for i in 0..<4 { seconds = seconds << 8 | UInt32(bytes[index + i]) }
        for i in 4..<8 { fraction = fraction << 8 | UInt32(bytes[index + i]) }
        if seconds == 0 && fraction == 0 { return 0 }
        return Double(seconds) - ntpToUnix + Double(fraction) / 4_294_967_296.0
    }
}

/// Guards the continuation against the double-resume a timeout racing a
/// response would otherwise cause.
private final class Resumer {
    private var continuation: CheckedContinuation<SNTPSample, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<SNTPSample, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: SNTPSample) { take()?.resume(returning: value) }
    func fail(_ error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<SNTPSample, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
