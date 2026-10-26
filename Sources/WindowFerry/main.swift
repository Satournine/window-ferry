import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var menu: MenuPanelController!
    private var settings: NSWindow?
    private var model: FerryModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard quitOtherCopies() else { NSApp.terminate(nil); return }
        model = FerryModel()
        menu = MenuPanelController()
        menu.onClose = { [weak self] in self?.model.menuClosed() }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.closeMenu = { [weak self] in self?.menu.close() }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusIcon()
            button.toolTip = "Window Ferry — bring windows to this display"
            button.target = self; button.action = #selector(toggleMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // First run: show the panel so the Accessibility setup is visible.
        if !model.trusted { openMenuWhenIconIsPlaced() }
    }

    /// Menu-bar glyph matching the app icon: a window riding a ferry hull over a wave.
    /// Template image, so macOS tints it for light, dark, and tinted menu bars.
    private static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let frame = NSRect(x: 4.5, y: 1.5, width: 10, height: 7.5)
            let window = NSBezierPath(roundedRect: frame, xRadius: 1.6, yRadius: 1.6)
            window.lineWidth = 1.3
            window.stroke()
            NSGraphicsContext.saveGraphicsState()
            window.addClip()
            NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 2.4).fill()  // title bar
            NSGraphicsContext.restoreGraphicsState()
            let hull = NSBezierPath()
            hull.move(to: NSPoint(x: 1.5, y: 10.4))
            hull.line(to: NSPoint(x: 17, y: 10.4))
            hull.curve(to: NSPoint(x: 13.6, y: 14.2), controlPoint1: NSPoint(x: 16, y: 12.6), controlPoint2: NSPoint(x: 15, y: 13.9))
            hull.line(to: NSPoint(x: 4.2, y: 14.2))
            hull.close()
            hull.fill()
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 1, y: 16.6))
            wave.curve(to: NSPoint(x: 9, y: 16.6), controlPoint1: NSPoint(x: 3.5, y: 15.2), controlPoint2: NSPoint(x: 6.5, y: 18))
            wave.curve(to: NSPoint(x: 17, y: 16.6), controlPoint1: NSPoint(x: 11.5, y: 15.2), controlPoint2: NSPoint(x: 14.5, y: 18))
            wave.lineWidth = 1.2
            wave.lineCapStyle = .round
            wave.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Window Ferry"
        return image
    }

    /// Two running copies would fight over the same status item and shortcuts.
    private func quitOtherCopies() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Window Ferry is already running"
        alert.informativeText = "Quit the other copy and continue with this one?"
        alert.addButton(withTitle: "Quit Other Copy")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        others.forEach { $0.terminate() }
        return true
    }

    @objc private func toggleMenu() {
        if menu.isShown { menu.close() }
        else { openMenu(at: NSEvent.mouseLocation) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMenu()
        return false
    }
    /// The status item's on-screen center, or nil before the menu bar has placed it (its frame is empty then).
    private var iconCenter: NSPoint? {
        guard let frame = item.button?.window?.frame, frame.height > 0 else { return nil }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// At launch the menu bar places the icon a moment later (~0.1 s); wait briefly so the panel opens under it.
    private func openMenuWhenIconIsPlaced(attempts: Int = 10) {
        guard iconCenter == nil, attempts > 0 else { openMenu(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.openMenuWhenIconIsPlaced(attempts: attempts - 1) }
    }

    /// A click opens at the pointer: every display's menu bar has its own copy of the icon, and the
    /// pointer says which was clicked. Other opens (launch, reopen) anchor under the status item.
    private func openMenu(at point: NSPoint? = nil) {
        guard !menu.isShown else { return }
        let anchor = point ?? iconCenter ?? NSEvent.mouseLocation
        model.menuOpened(at: anchor)
        if !menu.show(model: model, at: anchor) { model.menuClosed() }
    }

    private func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.contentViewController = NSHostingController(rootView: FerrySettings(model: model))
            window.isReleasedWhenClosed = false
            settings = window
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }), let settings {
            let area = screen.visibleFrame
            settings.setFrameOrigin(NSPoint(x: area.midX - settings.frame.width / 2, y: area.midY - settings.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
