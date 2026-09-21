import AVFoundation
import Photos

/// Owns the capture session, the writer, and the frame loop.
///
/// The rule the whole design rests on: nothing on the per-frame path touches
/// the network or the wall clock. The anchor is measured before recording and
/// frozen for the clip, so a clock step mid-recording cannot reach the frames.
final class CaptureController: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var anchor: TimeAnchor?
    @Published private(set) var isSyncing = false
    @Published private(set) var overlayMicroseconds: Double = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var message: String?

    let session = AVCaptureSession()

    private let captureQueue = DispatchQueue(label: "timestampcam.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let overlay = TimestampOverlay()

    // Writer state below is touched only on captureQueue.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pendingStart = false
    private var sessionStarted = false
    private var frozenAnchor = TimeAnchor.fromSystemClock()
    private var gmtOffset = 0
    private var outputURL: URL?
    private var framesSinceReport = 0
    private var costSinceReport = 0.0

    private var elapsedTimer: Timer?
    private var syncTimer: Timer?
    private var recordingStartHost = 0.0

    /// How often to re-measure the anchor while idle and in the foreground.
    private static let resyncInterval: TimeInterval = 60

    /// Beyond this, the anchor and iOS's own clock can't both be right, and the
    /// anchor isn't trusted for a clip. They normally agree to tens of ms.
    private static let maxDisagreement: TimeInterval = 1

    // MARK: - Setup

    func start() {
        anchor = TimeAnchorStore.load()
        Task { await requestPermissions() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: Self.resyncInterval, repeats: true) { [weak self] _ in
            Task { await self?.sync() }
        }
    }

    private func requestPermissions() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            await publish { self.message = "Camera access denied. Enable it in Settings." }
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        captureQueue.async { self.configureSession() }
        await sync()
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput)
        else {
            session.commitConfiguration()
            publishAsync { self.message = "No camera available." }
            return
        }
        session.addInput(cameraInput)

        if let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // Ask for the sensor's native 4:2:0 layout. Anything else would force a
        // full-frame colour conversion on every frame.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // Keep every frame: we would rather do the work than lose a sample.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        videoOutput.connection(with: .video)?.videoOrientation = .portrait

        lockFrameRate(on: camera)

        session.commitConfiguration()
        session.startRunning()
    }

    /// Pins the frame duration so the recording is constant-rate.
    ///
    /// Left alone, the camera stretches frame duration to gather light, which is
    /// why a stock iPhone clip has uneven frame spacing. Fixing it costs some
    /// exposure in dim scenes and buys predictable timing.
    private func lockFrameRate(on camera: AVCaptureDevice) {
        let target = camera.activeFormat.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
            ? 60 : 30
        guard (try? camera.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(target))
        camera.activeVideoMinFrameDuration = duration
        camera.activeVideoMaxFrameDuration = duration
        camera.unlockForConfiguration()
    }

    // MARK: - Clock sync

    /// Re-measures the anchor. Runs at launch, on returning to the foreground,
    /// every minute while idle, and on tapping the clock badge -- never during a
    /// recording, whose anchor is frozen.
    @MainActor
    func sync() async {
        guard !isSyncing, !isRecording else { return }
        isSyncing = true
        defer { isSyncing = false }

        if let sample = await SNTPClient.measure() {
            let measured = TimeAnchor.from(sample)
            TimeAnchorStore.save(measured)
            anchor = measured
            message = nil
        } else if anchor == nil {
            message = "No time server reachable. Recordings will be marked unverified."
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        // Freeze the anchor now, corrected for any sleep since it was measured.
        // Whatever iOS does to its own clock during the clip cannot reach the
        // frames.
        var active = (anchor ?? .fromSystemClock()).correctedForSleep()

        // Independent check against iOS's own clock before stamping a clip.
        let disagreement = active.disagreementWithSystemClock
        if abs(disagreement) > Self.maxDisagreement {
            active = .fromSystemClock()
            message = String(format: "Synced clock was %.1f s off iOS's clock, so this clip uses iOS time (UNVERIFIED).",
                             disagreement)
        }

        let offset = TimeZone.current.secondsFromGMT()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimestampCam-\(Int(Date().timeIntervalSince1970)).mov")

        captureQueue.async {
            self.frozenAnchor = active
            self.gmtOffset = offset
            self.outputURL = url
            self.pendingStart = true
            self.sessionStarted = false
        }

        recordingStartHost = HostClock.now()
        elapsed = 0
        droppedFrames = 0
        isRecording = true
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.elapsed = HostClock.now() - self.recordingStartHost
        }
    }

    private func stopRecording() {
        isRecording = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        captureQueue.async {
            self.pendingStart = false
            guard let writer = self.writer, writer.status == .writing else {
                self.teardownWriter()
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let url = self.outputURL
            writer.finishWriting {
                if let url, writer.status == .completed {
                    self.saveToPhotos(url)
                } else {
                    self.publishAsync {
                        self.message = writer.error?.localizedDescription ?? "Recording failed."
                    }
                }
                self.captureQueue.async { self.teardownWriter() }
            }
        }
    }

    private func teardownWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
        outputURL = nil
    }

    /// Builds the writer once the first frame tells us the real dimensions.
    private func beginWriting(width: Int, height: Int) {
        guard let url = outputURL,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        else { return }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true
        // 600 ticks/second -- the QuickTime default -- quantises frame times to
        // 1.67 ms. The burned-in digits are unaffected either way, but there is
        // no reason to throw away resolution in the container.
        video.mediaTimeScale = 90_000
        if writer.canAdd(video) { writer.add(video) }

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) { writer.add(audio) }

        writer.startWriting()
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.publishAsync { self.message = "Saved to app storage; photo access denied." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                self.publishAsync {
                    self.message = success ? "Saved to Photos" : (error?.localizedDescription ?? "Save failed")
                }
                if success { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    // MARK: - Publishing to the UI

    private func publishAsync(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    @MainActor
    private func publish(_ work: @escaping () -> Void) async {
        work()
    }
}

// MARK: - Frame loop

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if pendingStart {
            beginWriting(width: CVPixelBufferGetWidth(pixelBuffer),
                         height: CVPixelBufferGetHeight(pixelBuffer))
            pendingStart = false
        }
        guard let writer, writer.status == .writing, let videoInput else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: presentation)
            sessionStarted = true
        }

        // The only per-frame clock work: one subtraction and one add.
        let unix = frozenAnchor.unixTime(forHost: CMTimeGetSeconds(presentation))

        let before = HostClock.now()
        overlay.draw(into: pixelBuffer,
                     unix: unix,
                     gmtOffset: gmtOffset,
                     degraded: frozenAnchor.isDegraded)
        reportCost(seconds: HostClock.now() - before)

        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        } else {
            // The encoder is behind. Count it: a silently missing frame is
            // worse than a visible one.
            publishAsync { self.droppedFrames += 1 }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput, sessionStarted else { return }
        publishAsync { self.droppedFrames += 1 }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted,
              let audioInput, audioInput.isReadyForMoreMediaData,
              let writer, writer.status == .writing
        else { return }
        audioInput.append(sampleBuffer)
    }

    /// Averages the overlay cost and publishes a few times a second, so the
    /// readout itself never becomes the expensive part.
    private func reportCost(seconds: Double) {
        costSinceReport += seconds * 1_000_000
        framesSinceReport += 1
        guard framesSinceReport >= 30 else { return }
        let average = costSinceReport / Double(framesSinceReport)
        costSinceReport = 0
        framesSinceReport = 0
        publishAsync { self.overlayMicroseconds = average }
    }
}
