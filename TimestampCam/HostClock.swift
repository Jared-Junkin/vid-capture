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
