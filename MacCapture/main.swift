// timestampcap: record one or more Mac windows with a synchronized
// HH:MM:SS:MMM timestamp burned into every frame.
//
//   ./build_mac.sh
//   .build/timestampcap [output-directory]
//
// Recordings go to the output directory (default: the current directory).
// Press Enter or Ctrl-C to stop; either one finishes the files cleanly.

import CoreGraphics
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1]
                          : FileManager.default.currentDirectoryPath)

// MARK: - Clock

print("Syncing clock...")
let anchor: TimeAnchor
if let sample = await SNTPClient.measure() {
    anchor = .from(sample)
    TimeAnchorStore.save(anchor)
    print(String(format: "  synced, +/-%.0f ms", (anchor.uncertainty ?? 0) * 1000))
} else if let stored = TimeAnchorStore.load() {
    anchor = stored
    print("  no time server reachable; using the anchor measured \(Int(stored.age / 60)) min ago")
} else {
    anchor = .fromSystemClock()
    print("  no time server reachable; using this Mac's clock. Recordings are marked UNVERIFIED.")
}

// MARK: - Window selection

let content: SCShareableContent
do {
    content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
} catch {
    print("""

    Can't list windows: \(error.localizedDescription)
    Grant Screen Recording permission: System Settings > Privacy & Security >
    Screen Recording > turn on your terminal app, then quit and reopen it.
    """)
    exit(1)
}

let windows = content.windows
    .filter { $0.windowLayer == 0 && !($0.title ?? "").isEmpty && $0.frame.width >= 100 && $0.frame.height >= 100 }
    .sorted { ($0.owningApplication?.applicationName ?? "", $0.title ?? "")
            < ($1.owningApplication?.applicationName ?? "", $1.title ?? "") }

guard !windows.isEmpty else {
    print("No recordable windows on screen.")
    exit(1)
}

print("\nWindows on screen:")
for (index, window) in windows.enumerated() {
    let app = window.owningApplication?.applicationName ?? "?"
    print(String(format: "  [%2d] %@ - %@  (%dx%d)", index + 1, app, window.title ?? "",
                 Int(window.frame.width), Int(window.frame.height)))
}

var chosen: [SCWindow] = []
while chosen.isEmpty {
    print("\nWindows to record (e.g. 1,3): ", terminator: "")
    guard let line = readLine() else { exit(0) }
    let numbers = line.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
    if !numbers.isEmpty, numbers.allSatisfy({ (1...windows.count).contains($0) }) {
        chosen = Array(Set(numbers)).sorted().map { windows[$0 - 1] }
    } else {
        print("Enter numbers between 1 and \(windows.count), separated by commas.")
    }
}

// MARK: - Recording

/// Captures happen at the display's pixel density, not its point size.
let scale: CGFloat = {
    guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 2 }
    return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
}()

func fileName(for window: SCWindow, at stamp: Int) -> String {
    let raw = "\(window.owningApplication?.applicationName ?? "window")-\(window.title ?? "")"
    let safe = raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
    return "\(String(safe.prefix(60)))-\(stamp).mov"
}

// Every window shares one frozen anchor, so their timestamps agree exactly.
// Correct it for any sleep since it was measured, then check it against this
// Mac's own clock before trusting it for the recording.
var clipAnchor = anchor.correctedForSleep()
if abs(clipAnchor.disagreementWithSystemClock) > 1 {
    print(String(format: "Synced clock is %.1f s off this Mac's clock; using the Mac's clock (UNVERIFIED).",
                 clipAnchor.disagreementWithSystemClock))
    clipAnchor = .fromSystemClock()
}
let gmtOffset = TimeZone.current.secondsFromGMT()
let stamp = Int(Date().timeIntervalSince1970)
var recorders: [WindowRecorder] = []

for window in chosen {
    let recorder = WindowRecorder(window: window, anchor: clipAnchor, gmtOffset: gmtOffset,
                                  outputURL: outputDirectory.appendingPathComponent(fileName(for: window, at: stamp)))
    do {
        try await recorder.start(scale: scale)
        recorders.append(recorder)
    } catch {
        print("Could not start \(window.title ?? "window"): \(error.localizedDescription)")
    }
}
guard !recorders.isEmpty else { exit(1) }

print("\nRecording \(recorders.count) window(s) to \(outputDirectory.path)")
print("Press Enter or Ctrl-C to stop.\n")

// Keep the Mac and its display awake: sleep would stop the capture.
let noSleep = ProcessInfo.processInfo.beginActivity(
    options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "Recording windows")

// Every minute, re-measure and ease every window's clock toward it, so drift
// can't build up over a long recording. Same measurement and host time for all.
let resyncTimer = DispatchSource.makeTimerSource(queue: .global())
resyncTimer.schedule(deadline: .now() + ClipClock.resyncInterval, repeating: ClipClock.resyncInterval)
resyncTimer.setEventHandler {
    Task {
        guard let sample = await SNTPClient.measure() else {
            print("\n  clock resync: no time server reachable, keeping current clock")
            return
        }
        let measured = TimeAnchor.from(sample)
        TimeAnchorStore.save(measured)
        let host = HostClock.now()
        let corrections = recorders.map { $0.correctClock(toward: measured, atHost: host) }
        if let correction = corrections.compactMap({ $0 }).first {
            print(String(format: "\n  clock resync: corrected %+.1f ms", correction * 1000))
        } else {
            print("\n  clock resync: measurement too noisy, keeping current clock")
        }
    }
}
resyncTimer.resume()

let startHost = HostClock.now()
let statusTimer = DispatchSource.makeTimerSource(queue: .global())
statusTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
statusTimer.setEventHandler {
    let elapsed = HostClock.now() - startHost
    let all = recorders.map(\.stats)
    let frames = all.reduce(0) { $0 + $1.frames }
    let dropped = all.reduce(0) { $0 + $1.dropped }
    let overlayCost = all.reduce(0.0) { $0 + $1.overlaySeconds } / Double(max(frames, 1)) * 1_000_000
    print(String(format: "\r\u{1B}[31m●\u{1B}[0m REC %02d:%04.1f  |  %d frames  |  overlay %.0f us/frame  |  dropped %d   ",
                 Int(elapsed) / 60, elapsed.truncatingRemainder(dividingBy: 60), frames, overlayCost, dropped),
          terminator: "")
}
statusTimer.resume()

// Enter and Ctrl-C both end the recording; whichever comes first wins.
var stopSignal: DispatchSourceSignal?
await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    let lock = NSLock()
    var resumed = false
    let finish = {
        lock.lock()
        defer { lock.unlock() }
        if !resumed { resumed = true; continuation.resume() }
    }
    signal(SIGINT, SIG_IGN)
    stopSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    stopSignal?.setEventHandler(handler: finish)
    stopSignal?.resume()
    Thread.detachNewThread { _ = readLine(); finish() }
}
statusTimer.cancel()
resyncTimer.cancel()
ProcessInfo.processInfo.endActivity(noSleep)

print("\n\nStopping...")
for recorder in recorders {
    let title = recorder.window.title ?? "window"
    let url = await recorder.stop()
    let stats = recorder.stats
    if let url {
        let lag = stats.firstFrameLag.map { String(format: ", first-frame clock lag %.1f ms", $0 * 1000) } ?? ""
        print("  saved \(url.lastPathComponent)  (\(stats.frames) frames, \(stats.dropped) dropped\(lag))")
    } else {
        print("  \(title): nothing written\(stats.error.map { " - \($0)" } ?? "")")
    }
}
