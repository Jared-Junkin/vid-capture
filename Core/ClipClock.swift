import Foundation

/// The host-clock-to-UTC mapping for one recording.
///
/// It starts from the anchor frozen at record start. Over a long recording the
/// device's crystal drifts from true time by a few to ~20 parts per million --
/// up to ~200 ms over a three-hour game -- so the recording re-measures every
/// `resyncInterval` and folds each measurement in with `correct(toward:)`. A
/// correction is eased in over a minute rather than applied at once, so the
/// timestamps stay continuous and never jump or run backwards.
struct ClipClock {

    /// How often a recording re-measures its clock.
    static let resyncInterval: TimeInterval = 15 * 60
    /// How long a correction takes to ease in.
    static let easeSeconds = 60.0
    /// Measurements noisier than this aren't worth correcting toward.
    static let maxUncertainty = 0.020
    /// Drift over one interval is milliseconds; a correction bigger than this
    /// means the measurement is wrong, not the clock.
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
