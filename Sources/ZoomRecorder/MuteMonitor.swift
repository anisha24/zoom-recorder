import AppKit
import ApplicationServices

enum MicState: Equatable {
    case unknown, muted, unmuted

    var label: String {
        switch self {
        case .unknown: return "Mic: Zoom mute state unknown (mic will be recorded)"
        case .muted: return "Mic: muted in Zoom (not recorded)"
        case .unmuted: return "Mic: live in Zoom (recorded)"
        }
    }
}

/// Polls Zoom's accessibility tree to learn whether the user is muted in the meeting.
/// Reads the meeting toolbar's Mute/Unmute button, falling back to the "Meeting" menu items.
final class MuteMonitor: @unchecked Sendable {
    static let zoomBundleID = "us.zoom.xos"

    var onChange: ((MicState) -> Void)?

    private let queue = DispatchQueue(label: "ZoomRecorder.MuteMonitor")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var _state: MicState = .unknown
    private var cachedButton: AXUIElement?
    private var lastWindowScan = Date.distantPast

    var state: MicState { lock.withLock { _state } }

    @discardableResult
    static func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            cachedButton = nil
            update(.unknown)
        }
    }

    private func update(_ new: MicState) {
        let changed: Bool = lock.withLock {
            defer { _state = new }
            return _state != new
        }
        if changed { onChange?(new) }
    }

    private func poll() {
        guard let zoom = NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomBundleID).first else {
            cachedButton = nil
            update(.unknown)
            return
        }

        if let button = cachedButton, let s = Self.classify(button) {
            update(s)
            return
        }
        cachedButton = nil

        let app = AXUIElementCreateApplication(zoom.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)

        // The toolbar can auto-hide, so full window scans are throttled; the menu bar is cheap to check.
        if Date().timeIntervalSince(lastWindowScan) >= 1 {
            lastWindowScan = Date()
            for window in Self.children(of: app, attribute: kAXWindowsAttribute) {
                var budget = 1500
                if let (button, s) = Self.search(window, depth: 14, budget: &budget) {
                    cachedButton = button
                    update(s)
                    return
                }
            }
        }

        if let menuBar = Self.element(of: app, attribute: kAXMenuBarAttribute) {
            var budget = 800
            if let (_, s) = Self.search(menuBar, depth: 4, budget: &budget) {
                update(s)
                return
            }
        }
        // Nothing found this round: keep the last known state rather than flapping.
    }

    // MARK: - Accessibility helpers

    private static let controlRoles: Set<String> = [kAXButtonRole, kAXMenuItemRole, kAXCheckBoxRole]

    private static func search(_ el: AXUIElement, depth: Int, budget: inout Int) -> (AXUIElement, MicState)? {
        guard budget > 0 else { return nil }
        budget -= 1
        if let role = string(of: el, attribute: kAXRoleAttribute), controlRoles.contains(role),
           let s = classify(el) {
            return (el, s)
        }
        guard depth > 0 else { return nil }
        for child in children(of: el, attribute: kAXChildrenAttribute) {
            if let found = search(child, depth: depth - 1, budget: &budget) { return found }
        }
        return nil
    }

    static func classify(_ el: AXUIElement) -> MicState? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let text = string(of: el, attribute: attr), let s = classify(text: text) { return s }
        }
        return nil
    }

    /// Zoom labels the control with the action it will perform: "Unmute" means you are currently muted.
    static func classify(text: String) -> MicState? {
        let t = text.lowercased()
            .split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        switch t {
        case "unmute", "unmute audio", "unmute my audio", "unmute microphone", "unmute my microphone": return .muted
        case "mute", "mute audio", "mute my audio", "mute microphone", "mute my microphone": return .unmuted
        default: return nil
        }
    }

    private static func string(of el: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(of el: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of el: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
