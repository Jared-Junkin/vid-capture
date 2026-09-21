import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CaptureController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var blinking = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
        .onAppear { camera.start() }
        // Coming back from the background is when a stale anchor is likeliest.
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await camera.sync() } }
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top) {
            if camera.isRecording { recordingBadge }
            Spacer()
            clockBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(blinking ? 0.2 : 1)
            Text("REC")
                .font(.caption.weight(.heavy))
            Text(elapsedText)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                blinking = true
            }
        }
        .onDisappear { blinking = false }
    }

    private var clockBadge: some View {
        Button {
            Task { await camera.sync() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: clockIcon)
                Text(clockText).font(.caption.weight(.semibold))
            }
            .foregroundStyle(clockColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .disabled(camera.isRecording || camera.isSyncing)
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if let message = camera.message {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }

            diagnostics
            recordButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    private var recordButton: some View {
        Button(action: camera.toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(width: camera.isRecording ? 32 : 60,
                           height: camera.isRecording ? 32 : 60)
            }
        }
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
        .animation(.easeInOut(duration: 0.18), value: camera.isRecording)
    }

    private var diagnostics: some View {
        HStack(spacing: 14) {
            Label(String(format: "%.0f us/frame", camera.overlayMicroseconds), systemImage: "timer")
            if camera.droppedFrames > 0 {
                Label("\(camera.droppedFrames) dropped", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.75))
    }

    // MARK: - Formatting

    private var elapsedText: String {
        let total = max(0, camera.elapsed)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let tenths = Int((total - total.rounded(.down)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    private var isVerified: Bool {
        guard let anchor = camera.anchor else { return false }
        return !anchor.isDegraded
    }

    private var clockColor: Color {
        isVerified ? .white : .orange
    }

    private var clockIcon: String {
        if camera.isSyncing { return "arrow.triangle.2.circlepath" }
        return isVerified ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var clockText: String {
        if camera.isSyncing { return "Syncing" }
        guard let anchor = camera.anchor, !anchor.isDegraded else { return "Unverified" }
        let milliseconds = Int(((anchor.uncertainty ?? 0) * 1000).rounded())
        return "+/-\(milliseconds) ms . \(ageText(anchor.age))"
    }

    private func ageText(_ age: TimeInterval) -> String {
        switch age {
        case ..<60: return "now"
        case ..<3600: return "\(Int(age / 60))m"
        case ..<86_400: return "\(Int(age / 3600))h"
        default: return "\(Int(age / 86_400))d"
        }
    }
}
