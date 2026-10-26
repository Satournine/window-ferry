import AppKit
import FerryCore

enum Displays {
    static func snapshot() -> [Display] {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            return Display(id: id, name: screen.localizedName,
                           frame: Geometry.axRect(fromAppKit: screen.frame, primaryHeight: primaryHeight),
                           usable: Geometry.axRect(fromAppKit: screen.visibleFrame, primaryHeight: primaryHeight),
                           safeTop: screen.safeAreaInsets.top)
        }
    }

    static func pointerID(in displays: [Display]) -> String? { id(at: NSEvent.mouseLocation, in: displays) }

    /// The display containing an AppKit global point.
    static func id(at p: NSPoint, in displays: [Display]) -> String? {
        let point = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        // Edge pixels can fall just outside every half-open frame; use the nearest display then.
        return (displays.first { $0.frame.contains(point) }
            ?? Geometry.display(for: CGRect(origin: point, size: CGSize(width: 1, height: 1)), in: displays))?.id
    }
}
