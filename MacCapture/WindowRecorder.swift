import AVFoundation
import ScreenCaptureKit

/// Records one window to a .mov with the timestamp burned into every frame.
///
/// The frame path is the iPhone app's: ScreenCaptureKit stamps each frame on
/// the host clock, the frozen anchor turns that into UTC, and TimestampOverlay
/// writes it into the 4:2:0 luma plane before the frame reaches the encoder.
final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Stats {
        var frames = 0
        var dropped = 0
        var overlaySeconds = 0.0
        /// Host clock minus the first frame's timestamp. Small and positive if
        /// the frame timestamps really are on the host clock, as assumed.
        var firstFrameLag: Double?
        var error: String?
    }

    let window: SCWindow
    let outputURL: URL

    private let anchor: TimeAnchor
    private let gmtOffset: Int
    private let queue = DispatchQueue(label: "timestampcap.window")
    private let overlay = TimestampOverlay()
    private let statsLock = NSLock()
    private var currentStats = Stats()

    // Touched only on `queue`.
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var stopping = false

    init(window: SCWindow, anchor: TimeAnchor, gmtOffset: Int, outputURL: URL) {
        self.window = window
        self.anchor = anchor
        self.gmtOffset = gmtOffset
        self.outputURL = outputURL
    }

    var stats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return currentStats
    }

    func start(scale: CGFloat) async throws {
        let config = SCStreamConfiguration()
        config.width = even(window.frame.width * scale)
        config.height = even(window.frame.height * scale)
        // The same native 4:2:0 layout the camera path uses, so the overlay can
        // write the corner of the luma plane without a colour conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.showsCursor = true

        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: config,
                              delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.sync { self.stream = stream }
    }

    /// Stops capture and finishes the file. Returns the URL if it was written.
    func stop() async -> URL? {
        let stream = queue.sync { self.stream }
        try? await stream?.stopCapture()

        let (writer, input) = queue.sync { () -> (AVAssetWriter?, AVAssetWriterInput?) in
            stopping = true
            return (self.writer, self.input)
        }
        guard let writer, writer.status == .writing else { return nil }
        input?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, !stopping, isComplete(sampleBuffer),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = CMTimeGetSeconds(presentation)

        if writer == nil {
            beginWriting(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            writer?.startSession(atSourceTime: presentation)
            updateStats { $0.firstFrameLag = HostClock.now() - host }
        }
        guard let writer, writer.status == .writing, let input else { return }

        // The only per-frame clock work: one subtraction and one add.
        let unix = anchor.unixTime(forHost: host)

        let before = HostClock.now()
        overlay.draw(into: pixels, unix: unix, gmtOffset: gmtOffset, degraded: anchor.isDegraded)
        let cost = HostClock.now() - before

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            updateStats { $0.frames += 1; $0.overlaySeconds += cost }
        } else {
            updateStats { $0.dropped += 1 }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        updateStats { $0.error = error.localizedDescription }
    }

    /// ScreenCaptureKit also delivers idle and blank frames with no new
    /// content; only complete frames carry an image worth stamping.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    private func beginWriting(width: Int, height: Int) {
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            updateStats { $0.error = "could not create \(outputURL.lastPathComponent)" }
            return
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = 90_000
        writer.add(input)
        writer.startWriting()
        self.writer = writer
        self.input = input
    }

    private func updateStats(_ change: (inout Stats) -> Void) {
        statsLock.lock()
        change(&currentStats)
        statsLock.unlock()
    }

    private func even(_ value: CGFloat) -> Int {
        max(2, Int(value) & ~1)
    }
}
