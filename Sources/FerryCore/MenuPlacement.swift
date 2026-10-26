import CoreGraphics

/// Menu placement stays in AppKit global points (bottom-left origin), separate from AX geometry.
public enum MenuPlacement {
    public static func frame(at click: CGPoint, visibleFrame: CGRect,
                             preferredSize: CGSize = CGSize(width: 450, height: 620), inset: CGFloat = 8) -> CGRect {
        let padding = max(0, min(inset, min(visibleFrame.width, visibleFrame.height) / 4))
        let area = visibleFrame.insetBy(dx: padding, dy: padding)
        let size = CGSize(width: min(preferredSize.width, area.width), height: min(preferredSize.height, area.height))
        let x = max(area.minX, min(click.x - size.width / 2, area.maxX - size.width))
        // Opening from a menu-bar click always starts at this screen's usable top edge.
        // Never use the status item's window coordinates: those can refer to another display.
        return CGRect(x: x, y: area.maxY - size.height, width: size.width, height: size.height)
    }
}
