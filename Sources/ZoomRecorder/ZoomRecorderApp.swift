import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) lazy var overlay = OverlayController(state: state)

    func applicationDidFinishLaunching(_ notification: Notification) {
        MuteMonitor.checkAccessibilityPermission(prompt: true)
        overlay.show()
    }

    /// Opening the app again from Finder/Launchpad brings the overlay back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.show()
        return false
    }
}

@main
struct ZoomRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: appDelegate.state, overlay: appDelegate.overlay)
        } label: {
            MenuBarIcon(state: appDelegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.isRecording ? "record.circle.fill" : "record.circle")
    }
}

private struct MenuContent: View {
    @ObservedObject var state: AppState
    let overlay: OverlayController

    var body: some View {
        switch state.phase {
        case .idle:
            Button("Start Recording Zoom Meeting") { state.toggleRecording() }
                .keyboardShortcut("r")
        case .starting:
            Text("Starting…")
        case .recording(let since):
            Text("Recording since \(since.formatted(date: .omitted, time: .shortened))")
            Text(state.capturedWindows == 1 ? "Capturing 1 Zoom window" : "Capturing \(state.capturedWindows) Zoom windows")
            Button("Stop & Save") { state.toggleRecording() }
                .keyboardShortcut("s")
        case .saving:
            Text("Saving recording…")
        }
        Text(state.accessibilityTrusted ? state.micState.label : "Mic: grant Accessibility access to detect Zoom mute")

        if let message = state.message {
            Text(message)
        }

        Divider()

        Button("Show / Hide Overlay") { overlay.toggle() }
            .keyboardShortcut("o")
        Button("Move Overlay to Top Right") {
            overlay.moveToDefaultPosition()
            overlay.show()
        }
        if !state.accessibilityTrusted {
            Button("Grant Accessibility Access…") { state.openAccessibilitySettings() }
        }
        if state.lastRecording != nil {
            Button("Show Last Recording in Finder") { state.revealLastRecording() }
        }
        Picker("Video Quality", selection: $state.quality) {
            ForEach(RecordingQuality.allCases) { Text($0.label).tag($0) }
        }
        .disabled(state.phase != .idle)
        Button("Open Recordings Folder") { state.openFolder() }
        Button("Change Recordings Folder…") { state.chooseFolder() }
        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Quit Zoom Recorder") {
            Task {
                await state.stop()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }
}
