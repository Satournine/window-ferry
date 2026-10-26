import AppKit
import ApplicationServices
import FerryCore

struct AppRecord { let pid: pid_t; let name: String }
struct RoutingConfiguration {
    var displays: [Display] = []
    var ignored: Set<String> = []
    var preferred: String?
    var enabled = true
    var armed: Bool { enabled && !ignored.isEmpty }
    var destination: Display? {
        // CGEvent gives the live pointer in global top-left points, the same space as Display.frame.
        let pointer = CGEvent(source: nil).flatMap { event in displays.first { $0.frame.contains(event.location) }?.id }
        return Geometry.destination(displays: displays, ignored: ignored, pointer: pointer, preferred: preferred)
    }
}

struct ScanResult {
    var windows: [ManagedWindow]
    var unavailableApps: [String]
    var observerFailures: Int
}

/// AX messaging is confined to one worker queue. The menu never waits on another app.
final class WindowService {
    private let queue = DispatchQueue(label: "io.github.satournine.accessibility", qos: .userInitiated)
    private var configuration = RoutingConfiguration()
    private var apps: [pid_t: String] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var discovery = WindowDiscovery<WindowID>()
    private var generation = 0
    private var monitoring = false
    private var failedObservers: Set<pid_t> = []
    private var baselinePending: Set<pid_t> = []
    private var quietUntil = DispatchTime.now()
    var onAutomaticResult: ((String) -> Void)?

    func configure(apps records: [AppRecord], configuration next: RoutingConfiguration) {
        queue.async { [self] in
            let wasMonitoring = monitoring
            configuration = next
            apps = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0.name) })
            discovery.remove { apps[$0.pid] == nil }
            baselinePending = baselinePending.filter { apps[$0] != nil }
            failedObservers = failedObservers.filter { apps[$0] != nil }
            for pid in Array(observers.keys) where apps[pid] == nil { removeObserver(pid) }
            monitoring = AXIsProcessTrusted() && next.armed
            if !monitoring {
                generation += 1
                for pid in Array(observers.keys) { removeObserver(pid) }
                discovery.seed([])
                baselinePending = []
                failedObservers = []
                return
            }
            // A failed observer is not retried until its app relaunches; the fallback scan covers it.
            for pid in apps.keys where observers[pid] == nil && !failedObservers.contains(pid) { installObserver(pid) }
            if !wasMonitoring {
                // Enabling ignore is not permission to sweep existing windows.
                generation += 1
                var baseline: Set<WindowID> = []
                for pid in apps.keys {
                    guard let windows = AX.windows(pid: pid) else { baselinePending.insert(pid); continue }
                    for window in windows { baseline.insert(WindowID(pid: pid, element: window)) }
                }
                discovery.seed(baseline)
            }
        }
    }

    func scan(completion: @escaping (ScanResult) -> Void) {
        queue.async { [self] in
            var windows: [ManagedWindow] = [], failures: [String] = []
            if AXIsProcessTrusted() {
                for (pid, name) in apps.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
                    guard let elements = AX.windows(pid: pid) else { failures.append(name); continue }
                    discover(pid, elements)
                    for element in elements {
                        if let window = AX.inspect(WindowID(pid: pid, element: element), app: name, displays: configuration.displays) { windows.append(window) }
                    }
                }
            }
            let result = ScanResult(windows: windows, unavailableApps: failures, observerFailures: failedObservers.count)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Routing-only fallback for apps without window-created notifications: lists windows, inspects only new ones.
    func poll() { queue.async { [self] in discoverAll() } }

    /// AXWindows usually lists only the current Space, so a Space switch reveals existing windows.
    /// Absorb them as known instead of routing them.
    // ponytail: fixed 2 s quiet period; widen it if slow Space animations still leak windows through.
    func spaceChanged() {
        queue.async { [self] in
            quietUntil = .now() + 2
            discoverAll()
            queue.asyncAfter(deadline: .now() + 1.5) { [self] in discoverAll() }
        }
    }

    private func discoverAll() {
        for pid in apps.keys { if let elements = AX.windows(pid: pid) { discover(pid, elements) } }
    }

    private func discover(_ pid: pid_t, _ elements: [AXUIElement]) {
        guard monitoring else { return }
        let absorbOnly = baselinePending.remove(pid) != nil || DispatchTime.now() < quietUntil
        for element in elements {
            let id = WindowID(pid: pid, element: element)
            if discovery.insert(id) && !absorbOnly { scheduleRouting(id) }
        }
    }

    private func installObserver(_ pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let service = Unmanaged<WindowService>.fromOpaque(context).takeUnretainedValue()
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            let id = WindowID(pid: pid, element: element)
            service.queue.async {
                guard service.monitoring, service.discovery.insert(id), !service.baselinePending.contains(pid) else { return }
                service.scheduleRouting(id)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { failedObservers.insert(pid); return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let result = AXObserverAddNotification(observer, application, kAXWindowCreatedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else { failedObservers.insert(pid); return }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeObserver(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func scheduleRouting(_ id: WindowID) {
        attemptRouting(id, generation: generation, attempt: 0)
    }

    private func attemptRouting(_ id: WindowID, generation expected: Int, attempt: Int) {
        let delays = [0.25, 0.65, 1.1]
        queue.asyncAfter(deadline: .now() + delays[attempt]) { [self] in
            guard expected == generation, monitoring, AXIsProcessTrusted(), let name = apps[id.pid] else { return }
            guard let window = AX.inspect(id, app: name, displays: configuration.displays),
                  let sourceID = window.displayID else {
                if attempt < 2 { attemptRouting(id, generation: expected, attempt: attempt + 1) }
                return
            }
            // A window may get its final position after creation; retry briefly, never chase it indefinitely.
            guard configuration.ignored.contains(sourceID) else {
                if attempt < 2 { attemptRouting(id, generation: expected, attempt: attempt + 1) }
                return
            }
            guard window.restriction == nil, window.minimized == false, let target = configuration.destination else { return }
            performMove(id, targetID: target.id, restore: false, activate: false) { [weak self] result in
                // This completion runs on the worker queue; successful routing never takes focus.
                switch result {
                case .success: self?.announce("Routed a new \(name) window to \(target.name).")
                case .failure(let error): self?.announce("Couldn’t route a new \(name) window: \(error.message)")
                }
            }
        }
    }

    private func announce(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onAutomaticResult?(message) }
    }

    struct MoveError: Error { let message: String }
    struct MoveSuccess { let note: String? }

    func move(_ id: WindowID, targetID: String, restore: Bool, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            // Menu moves leave the user's focus alone so the Ferry panel remains usable.
            performMove(id, targetID: targetID, restore: restore, activate: false) { [self] result in
                let message: String
                switch result {
                case .success(let result):
                    let name = configuration.displays.first { $0.id == targetID }?.name ?? "the selected display"
                    message = result.note ?? "Moved window to \(name)."
                case .failure(let error): message = error.message
                }
                DispatchQueue.main.async { completion(message) }
            }
        }
    }

    func bringAll(from sourceID: String, to targetID: String, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            guard AXIsProcessTrusted() else { DispatchQueue.main.async { completion("Enable Accessibility to move windows.") }; return }
            var candidates: [WindowID] = []
            var skipped = 0, unreadable = 0
            for (pid, name) in apps {
                guard let elements = AX.windows(pid: pid) else { unreadable += 1; continue }
                for element in elements {
                    let id = WindowID(pid: pid, element: element)
                    guard let window = AX.inspect(id, app: name, displays: configuration.displays), window.displayID == sourceID else { continue }
                    if window.restriction != nil || window.minimized != false { skipped += 1 }
                    else { candidates.append(id) }
                }
            }
            moveBatch(candidates, targetID: targetID, moved: 0, skipped: skipped, failed: 0, unreadable: unreadable, completion: completion)
        }
    }

    private func moveBatch(_ ids: [WindowID], targetID: String, moved: Int, skipped: Int, failed: Int,
                           unreadable: Int, completion: @escaping (String) -> Void) {
        guard let first = ids.first else {
            let message = "\(moved) moved · \(skipped) skipped · \(failed) failed" + (unreadable > 0 ? " · \(unreadable) apps unreadable" : "")
            DispatchQueue.main.async { completion(message) }
            return
        }
        performMove(first, targetID: targetID, restore: false, activate: false) { [self] result in
            let success: Bool
            switch result { case .success: success = true; case .failure: success = false }
            moveBatch(Array(ids.dropFirst()), targetID: targetID, moved: moved + (success ? 1 : 0), skipped: skipped,
                      failed: failed + (success ? 0 : 1), unreadable: unreadable, completion: completion)
        }
    }

    func moveFocused(pid: pid_t?, direction: Int?, here: String?, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            guard AXIsProcessTrusted() else { DispatchQueue.main.async { completion("Enable Accessibility to use window shortcuts.") }; return }
            guard let pid else { DispatchQueue.main.async { completion("No foreground app window.") }; return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let element = AX.element(application, kAXFocusedWindowAttribute) else {
                DispatchQueue.main.async { completion("The foreground app exposes no focused window.") }; return
            }
            let id = WindowID(pid: pid, element: element)
            let window = AX.inspect(id, app: apps[pid] ?? "App", displays: configuration.displays)
            let target: String?
            if let direction, let source = window?.displayID {
                target = Geometry.adjacent(to: source, direction: direction, displays: configuration.displays, ignored: configuration.ignored)?.id
            } else { target = here }
            guard let target else { DispatchQueue.main.async { completion("No available destination display.") }; return }
            performMove(id, targetID: target, restore: false, activate: true) { result in
                let message: String
                switch result { case .success(let result): message = result.note ?? "Window moved."
                case .failure(let error): message = error.message }
                DispatchQueue.main.async { completion(message) }
            }
        }
    }

    private func performMove(_ id: WindowID, targetID: String, restore: Bool, activate: Bool,
                             completion: @escaping (Result<MoveSuccess, MoveError>) -> Void) {
        func fail(_ message: String) { completion(.failure(MoveError(message: message))) }
        guard AXIsProcessTrusted() else { fail("Enable Accessibility to move windows."); return }
        guard let target = configuration.displays.first(where: { $0.id == targetID }), !configuration.ignored.contains(targetID) else {
            fail("The destination display is disconnected or unavailable."); return
        }
        guard let window = AX.inspect(id, app: apps[id.pid] ?? "App", displays: configuration.displays) else {
            fail("The window is no longer available. Refresh the list."); return
        }
        if let reason = window.restriction { fail(reason); return }
        if window.minimized == true {
            guard restore else { fail("Minimized window skipped. Use Restore & Move to… explicitly."); return }
            let result = AXUIElementSetAttributeValue(id.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else { fail(AX.errorText(result)); return }
            queue.asyncAfter(deadline: .now() + 0.25) { [self] in
                performMove(id, targetID: targetID, restore: false, activate: activate, completion: completion)
            }
            return
        }
        guard let frame = window.frame else { fail("Window position unavailable."); return }
        let source = configuration.displays.first { $0.id == window.displayID }
        let resizable = AX.settable(id.element, kAXSizeAttribute)
        let desired = Geometry.relocated(frame, from: source, to: target, resizable: resizable)
        if desired.size != frame.size {
            var size = desired.size
            let value = AXValueCreate(.cgSize, &size)!
            // Apps can impose a minimum size. Continue to move the title bar even if resize is refused.
            _ = AXUIElementSetAttributeValue(id.element, kAXSizeAttribute as CFString, value)
        }
        // Recalculate after resize so an app's actual minimum size is respected when positioning it.
        let actual = AX.frame(id.element) ?? frame
        var point = Geometry.relocated(actual, from: source, to: target, resizable: false).origin
        let result = AXUIElementSetAttributeValue(id.element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        guard result == .success else { fail(AX.errorText(result)); return }
        queue.asyncAfter(deadline: .now() + 0.18) { [self] in
            guard let currentTarget = configuration.displays.first(where: { $0.id == targetID }),
                  !configuration.ignored.contains(targetID) else { fail("Display configuration changed during the move."); return }
            guard let verified = AX.frame(id.element), Geometry.display(for: verified, in: configuration.displays)?.id == currentTarget.id,
                  abs(verified.minX - point.x) < 8, abs(verified.minY - point.y) < 8 else {
                fail("The app did not keep the requested position. It may manage its own layout or be in another Space."); return
            }
            let oversized = verified.width > currentTarget.usable.width + 2 || verified.height > currentTarget.usable.height + 2
            if activate {
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: id.pid)?.activate(options: [.activateIgnoringOtherApps])
                }
                _ = AXUIElementPerformAction(id.element, kAXRaiseAction as CFString)
            }
            completion(.success(MoveSuccess(note: oversized ? "Moved the title bar here; the app’s minimum size exceeds this display." : nil)))
        }
    }
}
