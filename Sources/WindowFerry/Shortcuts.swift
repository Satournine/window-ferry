import AppKit
import Carbon
import SwiftUI

enum ShortcutAction: UInt32, CaseIterable, Identifiable {
    case previous = 1, next = 2, bringHere = 3
    var id: UInt32 { rawValue }
    var title: String {
        switch self { case .previous: return "Move to previous display"; case .next: return "Move to next display"; case .bringHere: return "Bring focused window here" }
    }
    var defaultShortcut: Shortcut {
        let code: UInt32 = self == .previous ? 123 : self == .next ? 124 : 4
        return Shortcut(keyCode: code, modifiers: UInt32(controlKey | optionKey | shiftKey), label: self == .previous ? "←" : self == .next ? "→" : "H")
    }
}

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
    var description: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + label
    }
    func sameKeys(as other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Control or Command avoids character-entry combinations and OS-version restrictions.
        guard flags.contains(.control) || flags.contains(.command) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let arrows: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑"]
        let label: String
        if let arrow = arrows[event.keyCode] { label = arrow }
        else if let chars = event.characters(byApplyingModifiers: [])?.uppercased(), chars.count == 1,
                chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) { label = chars }
        else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
}

final class HotKeys {
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    var onAction: ((ShortcutAction) -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x57465259, let action = ShortcutAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { manager.onAction?(action) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func unregister() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
    }

    func register(_ shortcuts: [ShortcutAction: Shortcut]) -> [ShortcutAction: String] {
        unregister()
        var failures: [ShortcutAction: String] = [:]
        guard handler != nil else {
            return Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, "Could not install shortcut handler") })
        }
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: 0x57465259, id: action.rawValue),
                                            GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registrations.append(ref) }
            else { failures[action] = "Unavailable or reserved (\(status)). Choose another shortcut." }
        }
        return failures
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void
    let onRecording: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = onChange; button.onRecording = onRecording
        return button
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange; view.onRecording = onRecording
        if !view.recording { view.title = shortcut?.description ?? "Click to record" }
    }
}

final class RecorderButton: NSButton {
    var shortcut: Shortcut?
    var onChange: ((Shortcut?) -> Void)?
    var onRecording: ((Bool) -> Void)?
    var recording = false
    private var windowObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self; action = #selector(begin)
        toolTip = "Click, then press Control or Command with a letter, number, or arrow. Escape cancels; Delete clears."
        setAccessibilityLabel("Record keyboard shortcut")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if recording { finish() }
        guard let window else { windowObserver = nil; return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            if self?.recording == true { self?.finish() }
        }
    }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    @objc private func begin() {
        window?.makeFirstResponder(self)
        recording = true; title = "Press shortcut…"; onRecording?(true)
    }
    private func finish() {
        recording = false; title = shortcut?.description ?? "Click to record"; onRecording?(false)
    }
    override func resignFirstResponder() -> Bool {
        if recording { finish() }
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 51 || event.keyCode == 117 { finish(); onChange?(nil); return }
        guard let value = Shortcut.from(event) else { title = "Use ⌃ or ⌘ + key"; return }
        // Finish first: it re-registers the old set, then onChange applies (or rejects) the new one.
        shortcut = value; finish(); onChange?(value)
    }
}
