import AppKit
import ApplicationServices
import SwiftUI
import FerryCore

final class FerryModel: ObservableObject {
    @Published var displays: [Display] = []
    @Published var windows: [ManagedWindow] = []
    @Published var ignored: Set<String>
    @Published var hereID: String?
    @Published var trusted = false
    @Published var loading = false
    @Published var moving = false
    @Published var message = "Choose a destination beside a window."
    @Published var unavailableApps: [String] = []
    @Published var observerFailures = 0
    @Published var shortcuts: [ShortcutAction: Shortcut] = [:]
    @Published var shortcutErrors: [ShortcutAction: String] = [:]
    @Published var routingEnabled: Bool {
        didSet { defaults.set(routingEnabled, forKey: "routingEnabled"); configure() }
    }
    var showSettings: (() -> Void)?
    var closeMenu: (() -> Void)?
    private var preferredID: String?
    private let defaults = UserDefaults.standard
    private let service = WindowService()
    private let hotKeys = HotKeys()
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var tick = 0
    private var menuVisible = false
    private var icons: [pid_t: NSImage] = [:]
    private var prompted = false

    var here: Display? { displays.first { $0.id == hereID } }

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredDisplays") ?? [])
        routingEnabled = UserDefaults.standard.object(forKey: "routingEnabled") as? Bool ?? true
        for action in ShortcutAction.allCases {
            let key = "shortcut.\(action.rawValue)"
            if let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Shortcut.self, from: data) { shortcuts[action] = stored }
            else if !defaults.bool(forKey: "disabled.\(action.rawValue)") { shortcuts[action] = action.defaultShortcut }
        }
        hotKeys.onAction = { [weak self] in self?.handleShortcut($0) }
        shortcutErrors = hotKeys.register(shortcuts)
        service.onAutomaticResult = { [weak self] message in
            self?.message = message
            if self?.menuVisible == true { self?.refresh() }
        }
        updateDisplays()
        trusted = AXIsProcessTrusted()
        configure()
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateDisplays(); self?.configure(); self?.refreshIfVisible()
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.icons = [:]; self?.configure(); self?.refreshIfVisible()
            })
        }
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.service.spaceChanged()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.heartbeat() }
        timer?.tolerance = 0.3
    }

    private func heartbeat() {
        let permission = AXIsProcessTrusted()
        if permission != trusted {
            trusted = permission
            if !permission { windows = []; message = "Accessibility access is off. Window control is paused." }
            else { message = "Accessibility enabled. Your windows are ready." }
            configure(); refresh()
        }
        tick += 1
        // Full inventory only while the panel is visible; routing alone needs a cheap 4 s discovery poll.
        guard trusted else { return }
        if menuVisible { configure(); refresh() }
        else if routingEnabled && !ignored.isEmpty && tick % 4 == 0 { configure(); service.poll() }
    }

    private func updateDisplays() {
        displays = Displays.snapshot()
        // A stale saved configuration must never leave every connected display unavailable.
        if !displays.isEmpty && displays.allSatisfy({ ignored.contains($0.id) }) {
            let fallback = Displays.pointerID(in: displays) ?? displays[0].id
            ignored.remove(fallback); persistIgnored()
            message = "Kept one connected display available after the display layout changed."
        }
        if !displays.contains(where: { $0.id == hereID }) { hereID = nil }
    }

    func menuOpened(at point: NSPoint) {
        menuVisible = true
        updateDisplays()
        hereID = Displays.id(at: point, in: displays) ?? Geometry.destination(displays: displays, ignored: ignored, pointer: nil, preferred: preferredID)?.id
        if let hereID, !ignored.contains(hereID) { preferredID = hereID }
        trusted = AXIsProcessTrusted()
        configure(); refresh()
    }
    func menuClosed() { menuVisible = false }

    private func configure() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }.map { AppRecord(pid: $0.processIdentifier, name: $0.localizedName ?? "App") }
        let config = RoutingConfiguration(displays: displays, ignored: ignored, preferred: preferredID, enabled: routingEnabled)
        service.configure(apps: apps, configuration: config)
    }

    func refresh() {
        checkAccessibility(showResult: false)
        guard !loading else { return }
        guard trusted else { windows = []; return }
        loading = true
        service.scan { [weak self] result in
            guard let self else { return }
            self.loading = false
            guard self.trusted else { return }
            let sorted = result.windows.sorted {
                if $0.app != $1.app { return $0.app.localizedStandardCompare($1.app) == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            // Publishing only real changes keeps the once-a-second refresh from re-rendering the panel.
            if sorted != self.windows { self.windows = sorted }
            if result.unavailableApps != self.unavailableApps { self.unavailableApps = result.unavailableApps }
            if result.observerFailures != self.observerFailures { self.observerFailures = result.observerFailures }
        }
    }
    private func refreshIfVisible() { if menuVisible { refresh() } }

    func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    func toggleIgnored(_ display: Display) {
        if ignored.contains(display.id) { ignored.remove(display.id) }
        else {
            guard displays.contains(where: { $0.id != display.id && !ignored.contains($0.id) }) else {
                message = "Keep at least one connected display available."; return
            }
            ignored.insert(display.id)
        }
        persistIgnored(); configure()
        message = ignored.contains(display.id)
            ? "\(display.name) is unavailable. " + (routingEnabled ? "New windows will be routed when possible. " : "") + "Existing windows stay until you move them."
            : "\(display.name) is available again. Moved windows stay where they are."
        refresh()
    }
    private func persistIgnored() { defaults.set(Array(ignored), forKey: "ignoredDisplays") }

    func canMove(to display: Display) -> Bool {
        trusted && !moving && !ignored.contains(display.id) && displays.contains(where: { $0.id == display.id })
    }
    func destinationLabel(_ display: Display) -> String {
        let index = displays.firstIndex(where: { $0.id == display.id }).map { $0 + 1 } ?? 0
        return "\(index). \(display.name)" + (display.id == hereID ? " (This Display)" : "")
            + (ignored.contains(display.id) ? " — Unavailable" : "")
    }
    func move(_ window: ManagedWindow, to display: Display) {
        guard canMove(to: display), window.restriction == nil else { return }
        moving = true; message = "Moving window to \(display.name)…"
        configure()
        service.move(window.id, targetID: display.id, restore: window.minimized == true) { [weak self] in self?.completed($0) }
    }
    func moveAll(from source: Display, to target: Display) {
        guard source.id != target.id, canMove(to: target) else { return }
        moving = true; message = "Moving windows to \(target.name)…"
        configure()
        service.bringAll(from: source.id, to: target.id) { [weak self] in self?.completed($0) }
    }
    private func completed(_ result: String) { moving = false; message = result; refresh() }

    func requestAccessibility() {
        closeMenu?()
        message = "Turn on Window Ferry in Privacy & Security → Accessibility."
        // The system prompt registers the app and offers its own Open System Settings button.
        // macOS may not show it again, so later requests open Settings directly.
        guard prompted else {
            prompted = true
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        openAccessibilitySettings()
    }
    func checkAccessibility(showResult: Bool = true) {
        let current = AXIsProcessTrusted()
        let changed = trusted != current
        if changed {
            trusted = current
            configure()
            if current { message = "Accessibility enabled. Your windows are ready." }
        }
        if !current { windows = []; unavailableApps = [] }
        if showResult {
            message = current
                ? "Accessibility is on. Refreshing windows…"
                : "Accessibility is still off. Turn on Window Ferry in Privacy & Security → Accessibility."
            if current { refresh() }
        }
    }
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func recording(_ recording: Bool) {
        if recording { hotKeys.unregister() } else { shortcutErrors = hotKeys.register(shortcuts) }
    }
    func setShortcut(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        if let shortcut, shortcuts.contains(where: { $0.key != action && $0.value.sameKeys(as: shortcut) }) {
            shortcutErrors[action] = "Already assigned to another Window Ferry action."; return
        }
        shortcuts[action] = shortcut
        defaults.set(shortcut == nil, forKey: "disabled.\(action.rawValue)")
        if let shortcut { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut.\(action.rawValue)") }
        else { defaults.removeObject(forKey: "shortcut.\(action.rawValue)") }
        shortcutErrors = hotKeys.register(shortcuts)
    }
    func resetShortcuts() {
        for action in ShortcutAction.allCases { setShortcut(action, nil) }
        for action in ShortcutAction.allCases { setShortcut(action, action.defaultShortcut) }
    }
    private func handleShortcut(_ action: ShortcutAction) {
        guard !moving else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        configure()
        let target = Displays.pointerID(in: displays)
        moving = true
        service.moveFocused(pid: pid, direction: action == .bringHere ? nil : action == .previous ? -1 : 1, here: target) { [weak self] result in
            self?.completed(result)
        }
    }
}
