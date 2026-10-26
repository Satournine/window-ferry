import AppKit
import SwiftUI
import FerryCore

enum AppVersion {
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
}

private final class MenuPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// A menu-like panel explicitly bounded to the clicked screen, independent of status-item replicas.
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let panel: MenuPanel
    private var screenObserver: NSObjectProtocol?
    private var presented = false
    var onClose: (() -> Void)?
    var isShown: Bool { presented && panel.isVisible }

    override init() {
        panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.close() }
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Borderless and clear: the glass view below is the panel's whole visible surface.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.title = "Window Ferry"
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close()
        }
    }

    @discardableResult
    func show(model: FerryModel, at click: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(click, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first else { return false }
        let frame = MenuPlacement.frame(at: click, visibleFrame: screen.visibleFrame,
                                        preferredSize: CGSize(width: 500, height: 630))
        let host = NSHostingView(rootView: FerryMenu(model: model, size: frame.size))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = Self.glass(around: host, cornerRadius: 22)
        // Quick menu-like entrance: fade in while settling a few points down into place.
        let start = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? frame : frame.offsetBy(dx: 0, dy: 8)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        presented = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            // Ending on the bounded frame also undoes any initial placement adjustment by AppKit.
            panel.animator().setFrame(frame, display: true)
        }
        return true
    }

    /// Liquid Glass on macOS 26 and later; the classic popover material before that.
    private static func glass(around content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.maskImage = NSImage(size: NSSize(width: cornerRadius * 2 + 1, height: cornerRadius * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill(); return true
        }
        effect.maskImage?.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    func close() {
        guard presented else { return }
        presented = false
        onClose?()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.presented else { return }  // Reopened while fading out.
            self.panel.orderOut(nil)
            self.panel.contentView = nil  // A hidden SwiftUI host would keep re-rendering on every model change.
        })
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
