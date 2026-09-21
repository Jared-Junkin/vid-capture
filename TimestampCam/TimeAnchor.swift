import Foundation

/// A frozen mapping from the host clock to UTC.
///
/// Measured rarely, applied constantly. Nothing on the per-frame path ever
/// calls `Date()`: when iOS steps its wall clock mid-recording -- which it does
/// as soon as a phone that has been offline reacquires service -- an anchor
/// captured before the clip keeps every frame's timestamp continuous and
/// monotonic. The step is ignored by construction.
struct TimeAnchor: Codable {

    enum Source: String, Codable {
        case sntp
        case systemClock
    }

    let unixAtAnchor: Double
    let hostAtAnchor: Double
    /// Half the round-trip, which is the standard NTP bound on how wrong the
    /// offset can be. Nil when we never measured and fell back to iOS's clock.
    let uncertainty: Double?
    let source: Source
    let bootID: String
    let measuredAt: Date

    func unixTime(forHost host: Double) -> Double {
        unixAtAnchor + (host - hostAtAnchor)
    }

    var isDegraded: Bool { source == .systemClock }

    var age: TimeInterval { Date().timeIntervalSince(measuredAt) }

    static func from(_ sample: SNTPSample) -> TimeAnchor {
        TimeAnchor(unixAtAnchor: sample.hostTime + sample.offset,
                   hostAtAnchor: sample.hostTime,
                   uncertainty: sample.delay / 2,
                   source: .sntp,
                   bootID: HostClock.bootID,
                   measuredAt: Date())
    }

    /// Fallback when we have never reached a time server. iOS's own clock is
    /// usually reasonable, but it is unverified and the overlay says so.
    static func fromSystemClock() -> TimeAnchor {
        let host = HostClock.now()
        return TimeAnchor(unixAtAnchor: Date().timeIntervalSince1970,
                          hostAtAnchor: host,
                          uncertainty: nil,
                          source: .systemClock,
                          bootID: HostClock.bootID,
                          measuredAt: Date())
    }
}

/// Persists the last good anchor so a recording made with no signal still has a
/// measured reference.
///
/// Known limit: we store the offset but do not learn the oscillator's rate
/// error, so a stored anchor drifts at the crystal's own rate -- on the order of
/// a second per day. Sync before going out and this never matters; the UI shows
/// the anchor's age so a stale one is obvious.
enum TimeAnchorStore {

    private static let key = "timestampcam.anchor"

    static func save(_ anchor: TimeAnchor) {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Returns the stored anchor only if it is still valid for this boot.
    static func load() -> TimeAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let anchor = try? JSONDecoder().decode(TimeAnchor.self, from: data),
              anchor.bootID == HostClock.bootID
        else { return nil }
        return anchor
    }
}
