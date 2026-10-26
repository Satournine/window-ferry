import Foundation
import CoreGraphics

/// All geometry in this module uses global logical points, with a top-left origin (AX).
public struct Display: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let frame: CGRect
    public let usable: CGRect
    public let safeTop: CGFloat

    public init(id: String, name: String, frame: CGRect, usable: CGRect, safeTop: CGFloat = 0) {
        self.id = id; self.name = name; self.frame = frame; self.usable = usable; self.safeTop = safeTop
    }
}

public enum Geometry {
    public static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func display(for window: CGRect, in displays: [Display]) -> Display? {
        guard !displays.isEmpty else { return nil }
        // Largest overlap handles windows spanning two displays. Nearest center rescues offscreen windows.
        return displays.max { a, b in
            let areaA = overlap(window, a.frame), areaB = overlap(window, b.frame)
            if areaA != areaB { return areaA < areaB }
            return distance(window, a.frame) > distance(window, b.frame)
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        pow(a.midX - b.midX, 2) + pow(a.midY - b.midY, 2)
    }

    /// Conservative public-API heuristic. This is deliberately NOT a claim to know a window's Space.
    public static func isScreenSized(_ window: CGRect, on display: Display) -> Bool {
        let f = display.frame
        return abs(window.minX - f.minX) <= 3 && abs(window.width - f.width) <= 3
            && window.minY >= f.minY - 3 && window.minY <= f.minY + display.safeTop + 3
            && window.maxY >= f.maxY - 3
    }

    public static func relocated(_ window: CGRect, from source: Display?, to target: Display,
                                 resizable: Bool) -> CGRect {
        let old = source?.usable ?? window
        let area = target.usable
        let size = resizable
            ? CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            : window.size
        // Preserve proportional location within the source's available travel, without scaling size.
        let xRatio = old.width > window.width ? (window.minX - old.minX) / (old.width - window.width) : 0.5
        let yRatio = old.height > window.height ? (window.minY - old.minY) / (old.height - window.height) : 0.5
        let x = area.minX + max(0, min(1, xRatio)) * max(0, area.width - size.width)
        let y = area.minY + max(0, min(1, yRatio)) * max(0, area.height - size.height)
        // Oversized fixed-size windows keep their top-left/title bar reachable.
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    public static func destination(displays: [Display], ignored: Set<String>, pointer: String?,
                                   preferred: String?) -> Display? {
        let available = displays.filter { !ignored.contains($0.id) }
        return available.first { $0.id == pointer }
            ?? available.first { $0.id == preferred } ?? available.first
    }

    public static func adjacent(to source: String, direction: Int, displays: [Display],
                                ignored: Set<String>) -> Display? {
        let ordered = displays.sorted {
            if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
            if $0.frame.midY != $1.frame.midY { return $0.frame.midY < $1.frame.midY }
            return $0.id < $1.id
        }
        guard let index = ordered.firstIndex(where: { $0.id == source }), ordered.count > 1 else { return nil }
        for step in 1..<ordered.count {
            let i = (index + direction * step % ordered.count + ordered.count) % ordered.count
            if !ignored.contains(ordered[i].id) { return ordered[i] }
        }
        return nil
    }
}

/// Baseline before routing starts; rediscovery never makes an existing window "new".
public struct WindowDiscovery<ID: Hashable> {
    public private(set) var known: Set<ID> = []
    public init() {}
    public mutating func seed(_ ids: Set<ID>) { known = ids }
    public mutating func insert(_ id: ID) -> Bool { known.insert(id).inserted }
    public mutating func remove(where predicate: (ID) -> Bool) { known = known.filter { !predicate($0) } }
}
