import AppKit
import SwiftUI

/// Floating, always-on-top control that stays visible over full-screen Zoom and every Space.
@MainActor
final class OverlayController {
    private let panel: OverlayPanel

    init(state: AppState) {
        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 262, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Keeps the control out of anything you screen-share in Zoom.
        panel.sharingType = .none

        let host = NSHostingController(rootView: OverlayView(state: state))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host

        // Earlier builds autosaved the position; every launch now starts in the default corner.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame RecorderOverlay")
        host.view.layoutSubtreeIfNeeded()
        moveToDefaultPosition()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func toggle() { isVisible ? hide() : show() }

    /// Top-right corner of the main display (the one with the menu bar), just below the menu bar.
    func moveToDefaultPosition() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var size = panel.contentViewController?.view.fittingSize ?? .zero
        if size.width < 1 || size.height < 1 { size = panel.frame.size }
        let origin = NSPoint(x: visible.maxX - size.width - Self.margin,
                             y: visible.maxY - size.height - Self.margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static let margin: CGFloat = 12

    /// Brings the panel back if the display it was dragged to is disconnected.
    private func keepOnScreen() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            moveToDefaultPosition()
        }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Resize around the top-right corner (e.g. when a message appears) so the panel stays
    /// pinned below the menu bar instead of extending upward or off the right edge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if rect.origin == frame.origin, rect.size != frame.size {
            rect.origin.x = frame.maxX - rect.width
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }
}

/// SwiftUI's hosting view swallows mouse-downs, so `isMovableByWindowBackground` alone doesn't
/// let the panel be dragged. This view hands drags on empty areas back to the window server.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

private struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 22)
                    .overlay(WindowDragArea())
                    .help("Drag to move")
                recordButton
                statusText
                Spacer(minLength: 4)
                micIndicator
            }
            if let message = state.message, !state.isRecording {
                HStack(alignment: .top, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        state.dismissMessage()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                if state.lastRecording != nil {
                    Button("Show in Finder") { state.revealLastRecording() }
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 262, alignment: .leading)
        .background(WindowDragArea())
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(state.isRecording ? Color.red.opacity(0.6) : Color.white.opacity(0.08))
        )
    }

    @ViewBuilder private var recordButton: some View {
        switch state.phase {
        case .idle:
            Button { state.toggleRecording() } label: {
                Circle().fill(Color.red).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("Start recording the Zoom meeting")
        case .recording:
            Button { state.toggleRecording() } label: {
                RoundedRectangle(cornerRadius: 4).fill(Color.red).frame(width: 18, height: 18)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .help("Stop and save")
        case .starting, .saving:
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch state.phase {
        case .idle:
            Text("Record Zoom").font(.system(.callout, weight: .medium))
        case .starting:
            Text("Starting…").font(.callout)
        case .saving:
            Text("Saving…").font(.callout)
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.elapsed(from: since, to: context.date))
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.red)
            }
            if state.capturedWindows > 1 {
                Label("\(state.capturedWindows)", systemImage: "rectangle.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Recording \(state.capturedWindows) Zoom windows side by side")
            }
        }
    }

    private var micIndicator: some View {
        let (symbol, color, help): (String, Color, String) = {
            if !state.accessibilityTrusted {
                return ("exclamationmark.triangle.fill", .orange,
                        "Click to grant Accessibility access so Zoom's mute state can be detected.")
            }
            switch state.micState {
            case .muted: return ("mic.slash.fill", .secondary, "Muted in Zoom: your mic is not recorded.")
            case .unmuted: return ("mic.fill", .green, "Unmuted in Zoom: your mic is recorded.")
            case .unknown: return ("mic.badge.xmark", .orange,
                                   "Zoom mute state not detected; your mic will be recorded.")
            }
        }()
        return Button {
            if !state.accessibilityTrusted { state.openAccessibilitySettings() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
