import Foundation

/// The host-clock-to-UTC mapping for one recording.
///
/// It starts from the anchor frozen at record start. A phone's crystal can run
/// ~30 parts per million off true time -- about 2 ms per minute, measured on a
/// real 20-minute recording -- so the recording re-measures every minute and
/// folds each measurement in with `correct(toward:)`. Each correction is eased
/// in over 10 seconds, fully applied long before the next one, so the
/// timestamps stay continuous and never jump or run backwards.
struct ClipClock {

    /// How often a recording re-measures its clock.
    static let resyncInterval: TimeInterval = 60
    /// How long a correction takes to ease in.
    static let easeSeconds = 10.0
    /// Measurements noisier than this aren't worth correcting toward.
    static let maxUncertainty = 0.020
    /// Drift over one interval is a couple of milliseconds; a correction bigger
    /// than this means the measurement is wrong, not the clock.
    static let maxCorrection = 0.5

    let isDegraded: Bool
    private var unixAtBase: Double
    private var hostAtBase: Double
    /// The correction being eased in, starting at `hostAtBase`.
    private var easing = 0.0

    init(anchor: TimeAnchor) {
        unixAtBase = anchor.unixAtAnchor
        hostAtBase = anchor.hostAtAnchor
        isDegraded = anchor.isDegraded
    }

    /// Per frame: a subtraction, an add, and a clamp.
    func unixTime(forHost host: Double) -> Double {
        let elapsed = host - hostAtBase
        return unixAtBase + elapsed + easing * min(1, max(0, elapsed / Self.easeSeconds))
    }

    /// Eases this clock toward a fresh measurement, starting at `host`.
    /// Returns the correction in seconds, or nil if the measurement was rejected.
    mutating func correct(toward measured: TimeAnchor, atHost host: Double) -> Double? {
        guard let uncertainty = measured.uncertainty, uncertainty <= Self.maxUncertainty else { return nil }
        let current = unixTime(forHost: host)
        let error = measured.correctedForSleep().unixTime(forHost: host) - current
        guard abs(error) <= Self.maxCorrection else { return nil }
        unixAtBase = current
        hostAtBase = host
        easing = error
        return error
    }
}
