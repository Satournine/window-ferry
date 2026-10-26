import AppKit
import SwiftUI
import FerryCore

struct FerryMenu: View {
    @ObservedObject var model: FerryModel
    var size = CGSize(width: 500, height: 600)
    @State private var query = ""
    @State private var showUnsupported = false
    @State private var collapsed: Set<String> = []

    private var searchTerms: [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
    private func isUnsupported(_ window: ManagedWindow) -> Bool { !window.movable && !window.restorable && !window.screenSized }
    private var hiddenCount: Int { showUnsupported ? 0 : model.windows.filter(isUnsupported).count }
    private func matches(_ window: ManagedWindow) -> Bool {
        let text = window.app + " " + window.title
        return searchTerms.allSatisfy { text.localizedStandardContains($0) }
    }
    private func visible(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        windows.filter { (showUnsupported || !isUnsupported($0)) && matches($0) }
    }
    private func countLabel(_ count: Int) -> String { "\(count) " + (count == 1 ? "window" : "windows") }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Window Ferry").font(.headline)
                        Text(model.here.map { "Opened on \($0.name)" } ?? "No display").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    circleButton("arrow.clockwise", "Refresh Windows") { model.refresh() }
                        .disabled(model.loading || model.moving)
                    circleButton("xmark", "Close") { model.closeMenu?() }
                }
                NativeWindowSearch(text: $query, onCancel: { model.closeMenu?() }).frame(height: 28)
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.trusted { permissionCard }
                    ForEach(model.displays) { display in displaySection(display) }
                    let unknown = visible(model.windows.filter { $0.displayID == nil })
                    if !unknown.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Display Unknown").font(.subheadline.bold())
                            ForEach(unknown) { windowRow($0) }
                        }.padding(12).background(card, in: cardShape)
                    }
                    if model.displays.isEmpty {
                        Label("No connected display is available.", systemImage: "display.trianglebadge.exclamationmark")
                            .font(.subheadline).foregroundStyle(.secondary).padding(12)
                    }
                    if !model.unavailableApps.isEmpty {
                        Label("Couldn’t read: " + model.unavailableApps.joined(separator: ", "), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
                    }
                    if model.observerFailures > 0 {
                        Text("Some apps need periodic checks for new windows.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                    .help(model.message).accessibilityLabel("Status: \(model.message)")
                HStack(spacing: 10) {
                    Menu {
                        Button("Settings…") { model.closeMenu?(); model.showSettings?() }
                        Toggle("Show Unsupported Windows", isOn: $showUnsupported)
                        Divider()
                        Button("Quit Window Ferry") { NSApp.terminate(nil) }
                    } label: { Label("Options", systemImage: "gearshape") }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                    if hiddenCount > 0 {
                        Button("\(hiddenCount) unsupported hidden") { showUnsupported = true }
                            .buttonStyle(.link).font(.caption)
                            .help("Show auxiliary or read-only windows that apps don’t let Window Ferry move.")
                    }
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(width: size.width, height: size.height)
    }

    // Content sits on the panel's glass as soft tinted cards; glass is reserved for the panel and its controls.
    private var card: some ShapeStyle { Color.primary.opacity(0.06) }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    @ViewBuilder private func circleButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) { Image(systemName: symbol).frame(width: 14, height: 14) }
            .help(label).accessibilityLabel(label)
        if #available(macOS 26, *) { button.buttonStyle(.glass).buttonBorderShape(.circle) }
        else { button.buttonStyle(.borderless) }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Accessibility Access Required", systemImage: "hand.raised").font(.subheadline.bold())
            Text("Window Ferry needs Accessibility access to list and move windows. Turn it on in System Settings → Privacy & Security → Accessibility.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings…") { model.requestAccessibility() }.buttonStyle(.borderedProminent)
                Button("Check Again") { model.checkAccessibility() }
            }.controlSize(.small)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(card, in: cardShape)
    }

    private func displaySection(_ display: Display) -> some View {
        let all = model.windows.filter { $0.displayID == display.id }
        let listed = visible(all)
        let count = all.filter { showUnsupported || !isUnsupported($0) }.count
        let unavailable = model.ignored.contains(display.id)
        let index = (model.displays.firstIndex(where: { $0.id == display.id }) ?? 0) + 1
        return DisclosureGroup(isExpanded: Binding(
            get: { !collapsed.contains(display.id) },
            set: { if $0 { collapsed.remove(display.id) } else { collapsed.insert(display.id) } }
        )) {
            VStack(spacing: 0) {
                if unavailable {
                    Text(model.routingEnabled ? "New windows will avoid this display when possible." : "New-window routing is paused.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                if listed.isEmpty {
                    Text(!model.trusted ? "Accessibility access required" : model.loading && all.isEmpty ? "Loading windows…" : searchTerms.isEmpty ? "No windows to move" : "No matching windows")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
                ForEach(Array(listed.enumerated()), id: \.element.id) { item, window in
                    if item > 0 { Divider().padding(.leading, 30) }
                    windowRow(window)
                }
            }.padding(.top, 7)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "display").font(.system(size: 15)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("\(index). \(display.name)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if display.id == model.hereID { badge("This Display", color: .secondary) }
                        if unavailable { badge("Unavailable", color: .orange) }
                    }
                    Text(searchTerms.isEmpty ? countLabel(count) : "\(listed.count) of \(countLabel(count))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                Menu("Move All to…") {
                    ForEach(model.displays.filter { $0.id != display.id }) { destination in
                        Button(model.destinationLabel(destination)) { model.moveAll(from: display, to: destination) }
                            .disabled(!model.canMove(to: destination))
                    }
                }.fixedSize().controlSize(.small)
                    .disabled(!model.trusted || model.moving || model.displays.count < 2 || !searchTerms.isEmpty || !all.contains { $0.restriction == nil && $0.minimized == false })
                    .help(searchTerms.isEmpty ? "Move all normal windows from this display. Minimized and fullscreen-like windows are skipped." : "Clear search before moving all windows on a display.")
                Menu {
                    Button(unavailable ? "Mark as Available" : "Mark as Unavailable") { model.toggleIgnored(display) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for \(display.name)")
                    .help("Display Availability")
            }
        }.padding(12).background(card, in: cardShape)
    }

    private func windowRow(_ window: ManagedWindow) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = model.icon(for: window.id.pid) {
                    Image(nsImage: icon).resizable()
                } else { Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary) }
            }.frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(window.title.isEmpty ? "Untitled Window" : window.title)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(window.title)
                HStack(spacing: 5) {
                    Text(window.app).font(.system(size: 10)).foregroundStyle(.secondary)
                    if window.minimized == true { badge("Minimized", color: .secondary) }
                    if window.screenSized { badge("May Be Fullscreen", color: .secondary) }
                    else if window.restriction != nil { badge("Unavailable", color: .secondary) }
                }
            }
            Spacer(minLength: 4)
            Menu(window.minimized == true ? "Restore & Move to…" : "Move to…") {
                ForEach(model.displays.filter { $0.id != window.displayID || window.minimized == true }) { destination in
                    Button(model.destinationLabel(destination)) { model.move(window, to: destination) }
                        .disabled(!model.canMove(to: destination))
                }
            }.fixedSize().controlSize(.small)
                .disabled(!model.trusted || model.moving || window.restriction != nil || (model.displays.count < 2 && window.minimized != true))
                .help(window.restriction ?? "Choose an available destination display.")
                .accessibilityLabel("Move \(window.title) from \(window.app) to a display")
        }.padding(.vertical, 9)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct FerrySettings: View {
    @ObservedObject var model: FerryModel
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Window Ferry").font(.title3.bold())
                        Text("Version \(AppVersion.current)").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(shortcut: model.shortcuts[action], onChange: { model.setShortcut(action, $0) }, onRecording: model.recording)
                            .frame(width: 150, height: 24)
                    } label: {
                        Text(action.title)
                        if let error = model.shortcutErrors[action] { Text(error).foregroundStyle(.orange) }
                    }
                }
                Button("Restore Defaults") { model.resetShortcuts() }
            } header: { Text("Keyboard Shortcuts") } footer: {
                Text("Shortcuts act on the focused window. Click a shortcut, then press a new combination that includes ⌃ or ⌘.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Move new windows off unavailable displays", isOn: $model.routingEnabled)
            } header: { Text("Display Routing") } footer: {
                Text("Mark a display unavailable from its ⋯ menu in the Window Ferry panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Accessibility") {
                    HStack(spacing: 10) {
                        Label(model.trusted ? "Allowed" : "Not Allowed", systemImage: model.trusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.trusted ? Color.green : Color.orange)
                        Button("Open Settings…") { model.trusted ? model.openAccessibilitySettings() : model.requestAccessibility() }
                    }
                }
            } header: { Text("Permissions") } footer: {
                Text("Accessibility is used only to read and move windows. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 520, height: 520)
    }
}
