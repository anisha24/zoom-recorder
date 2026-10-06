import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, recording(since: Date), saving
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var micState: MicState = .unknown
    @Published private(set) var capturedWindows = 0
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var message: String?
    @Published private(set) var lastRecording: URL?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var outputFolder: URL {
        didSet { UserDefaults.standard.set(outputFolder.path, forKey: Self.folderKey) }
    }

    @Published var quality: RecordingQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey) }
    }

    private static let folderKey = "outputFolder"
    private static let qualityKey = "recordingQuality"
    private let muteMonitor = MuteMonitor()
    private var recorder: Recorder?
    private var finalURL: URL?
    private var trustTimer: Timer?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            outputFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Zoom Recordings", isDirectory: true)
        }
        quality = UserDefaults.standard.string(forKey: Self.qualityKey)
            .flatMap(RecordingQuality.init(rawValue:)) ?? .standard
        muteMonitor.onChange = { [weak self] state in
            Task { @MainActor in self?.micState = state }
        }
        // Runs for the app's lifetime so the overlay shows Zoom's mute state before recording starts.
        muteMonitor.start()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.accessibilityTrusted = AXIsProcessTrusted() }
        }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        message = nil

        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AppError("Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone.")
            }
            if !MuteMonitor.checkAccessibilityPermission(prompt: true) {
                message = "Accessibility access is off, so Zoom's mute state can't be read and your mic will always be recorded."
            }

            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let base = "Zoom Meeting \(formatter.string(from: Date()))"
            let rawURL = outputFolder.appendingPathComponent("\(base).raw.mov")
            finalURL = outputFolder.appendingPathComponent("\(base).mp4")

            let monitor = muteMonitor
            let recorder = Recorder(isMicMuted: { monitor.state == .muted })
            recorder.onUnexpectedStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.message = "Capture stopped: \(error.localizedDescription)"
                    await self.stop()
                }
            }
            recorder.onWindowCountChanged = { [weak self] count in
                Task { @MainActor in self?.capturedWindows = count }
            }

            try await recorder.start(outputURL: rawURL, quality: quality)
            self.recorder = recorder
            phase = .recording(since: Date())
        } catch {
            recorder = nil
            capturedWindows = 0
            phase = .idle
            message = error.localizedDescription
        }
    }

    func stop() async {
        guard isRecording, let recorder, let finalURL else { return }
        phase = .saving
        self.recorder = nil
        capturedWindows = 0

        do {
            let rawURL = try await recorder.stop()
            do {
                try await Mixdown.run(input: rawURL, output: finalURL)
                try? FileManager.default.removeItem(at: rawURL)
                lastRecording = finalURL
                message = "Saved \(finalURL.lastPathComponent)"
            } catch {
                lastRecording = rawURL
                message = "Kept the raw recording; mixing failed: \(error.localizedDescription)"
            }
        } catch {
            message = "Recording failed: \(error.localizedDescription)"
        }
        phase = .idle
    }

    func toggleRecording() {
        Task {
            switch phase {
            case .idle: await start()
            case .recording: await stop()
            case .starting, .saving: break
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputFolder)
    }

    func revealLastRecording() {
        guard let lastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
    }

    func openAccessibilitySettings() {
        MuteMonitor.checkAccessibilityPermission(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func dismissMessage() {
        message = nil
    }
}

struct AppError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
