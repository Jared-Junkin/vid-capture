import CoreMedia
import Darwin

/// The monotonic clock AVFoundation stamps capture buffers with.
///
/// This is the same clock behind `CMSampleBufferGetPresentationTimeStamp`, so a
/// reading here and a frame's PTS are directly comparable. It free-runs: NTP
/// cannot step it, the user cannot set it, timezone and DST do not touch it.
/// Every timestamp this app burns into a frame is derived from it.
enum HostClock {

    static func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Total time the device has spent asleep since boot, in seconds.
    ///
    /// The host clock stops while the device sleeps; `mach_continuous_time`
    /// keeps counting. Their difference is exactly the sleep, which is what lets
    /// an anchor measured before the phone was locked stay correct after it.
    static func sleepSinceBoot() -> Double {
        // Read the host clock first: the continuous clock is then never behind
        // it, so the unsigned subtraction can't underflow.
        let awake = mach_absolute_time()
        let continuous = mach_continuous_time()
        return Double(continuous - awake) * secondsPerTick
    }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    /// Identifies the current boot.
    ///
    /// The host clock restarts at boot, which makes a stored anchor's host-time
    /// reference meaningless. Comparing this tells us whether a saved anchor is
    /// still usable.
    static var bootID: String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "unknown" }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }
}
