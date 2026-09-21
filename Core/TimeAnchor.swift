import Foundation

/// A frozen mapping from the host clock to UTC.
///
/// Measured rarely, applied constantly. Nothing on the per-frame path ever
/// calls `Date()`: when iOS steps its wall clock mid-recording -- which it does
/// as soon as a phone that has been offline reacquires service -- an anchor
/// captured before the clip keeps every frame's timestamp continuous and
/// monotonic. The step is ignored by construction.
///
/// The host clock stops while the device sleeps, so an anchor is only valid for
/// the host clock as it ran when measured. `correctedForSleep()` shifts it by
/// any sleep since; call it when a recording starts.
struct TimeAnchor: Codable {

    enum Source: String, Codable {
        case sntp
        case systemClock
    }

    let unixAtAnchor: Double
    let hostAtAnchor: Double
    /// `HostClock.sleepSinceBoot()` when the anchor was measured.
    let sleepAtAnchor: Double
    /// Half the round-trip, which is the standard NTP bound on how wrong the
    /// offset can be. Nil when we never measured and fell back to iOS's clock.
    let uncertainty: Double?
    let source: Source
    let bootID: String
    let measuredAt: Date

    func unixTime(forHost host: Double) -> Double {
        unixAtAnchor + (host - hostAtAnchor)
    }

    /// This anchor, corrected for any sleep since it was measured.
    ///
    /// Without this, every minute the device spent asleep after the last sync
    /// puts timestamps a minute behind: a fixed jump, not drift. The device
    /// can't sleep while recording, so the corrected anchor holds for the clip.
    func correctedForSleep() -> TimeAnchor {
        let slept = HostClock.sleepSinceBoot() - sleepAtAnchor
        return TimeAnchor(unixAtAnchor: unixAtAnchor,
                          hostAtAnchor: hostAtAnchor - slept,
                          sleepAtAnchor: sleepAtAnchor + slept,
                          uncertainty: uncertainty,
                          source: source,
                          bootID: bootID,
                          measuredAt: measuredAt)
    }

    /// Seconds this anchor's time is ahead of the system wall clock right now.
    /// An independent check: the two normally agree to within tens of ms. Only
    /// meaningful on an anchor that has been corrected for sleep.
    var disagreementWithSystemClock: Double {
        unixTime(forHost: HostClock.now()) - Date().timeIntervalSince1970
    }

    var isDegraded: Bool { source == .systemClock }

    var age: TimeInterval { Date().timeIntervalSince(measuredAt) }

    static func from(_ sample: SNTPSample) -> TimeAnchor {
        TimeAnchor(unixAtAnchor: sample.hostTime + sample.offset,
                   hostAtAnchor: sample.hostTime,
                   sleepAtAnchor: HostClock.sleepSinceBoot(),
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
                          sleepAtAnchor: HostClock.sleepSinceBoot(),
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
/// a second per day. The app resyncs every minute while it has signal, so this
/// only matters for long stretches offline; the UI shows the anchor's age.
enum TimeAnchorStore {

    // Bumped when the stored format changed, so anchors saved before sleep
    // correction existed are never loaded.
    private static let key = "timestampcam.anchor.v2"

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
