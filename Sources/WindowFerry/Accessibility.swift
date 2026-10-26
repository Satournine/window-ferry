import AppKit
import ApplicationServices
import FerryCore

struct WindowID: Hashable {
    let pid: pid_t
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(pid); hasher.combine(CFHash(element)) }
}

struct ManagedWindow: Identifiable, Equatable {
    let id: WindowID
    let app: String
    let title: String
    let frame: CGRect?
    let displayID: String?
    let minimized: Bool?
    let movable: Bool
    let restorable: Bool
    let screenSized: Bool

    var restriction: String? {
        if frame == nil { return "Position unavailable" }
        if screenSized { return "Screen-sized / may be fullscreen — exit fullscreen or resize first" }
        if !movable && !(minimized == true && restorable) { return "App does not expose a movable window" }
        if minimized == nil { return "Window state unavailable" }
        return nil
    }
}

enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func windows(pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return value(app, kAXWindowsAttribute) as? [AXUIElement]
    }

    static func inspect(_ id: WindowID, app: String, displays: [Display]) -> ManagedWindow? {
        let element = id.element
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard value(element, kAXRoleAttribute) as? String == kAXWindowRole else { return nil }
        // Include dialogs for visibility, but never detach a sheet or move an auxiliary panel automatically.
        let standard = value(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
        let rect = frame(element)
        let display = rect.flatMap { Geometry.display(for: $0, in: displays) }
        return ManagedWindow(id: id, app: app, title: value(element, kAXTitleAttribute) as? String ?? "Untitled window",
                             frame: rect, displayID: display?.id, minimized: value(element, kAXMinimizedAttribute) as? Bool,
                             movable: standard && settable(element, kAXPositionAttribute),
                             restorable: standard && settable(element, kAXMinimizedAttribute),
                             screenSized: rect.map { r in display.map { Geometry.isScreenSized(r, on: $0) } ?? false } ?? false)
    }

    static func errorText(_ error: AXError) -> String {
        switch error {
        case .apiDisabled: return "Accessibility permission is unavailable."
        case .cannotComplete: return "The app did not respond in time. Try again."
        case .invalidUIElement: return "That window has closed or changed. Refresh the list."
        case .attributeUnsupported, .notImplemented: return "The app does not support this operation."
        default: return "The app refused the change (Accessibility error \(error.rawValue))."
        }
    }
}
