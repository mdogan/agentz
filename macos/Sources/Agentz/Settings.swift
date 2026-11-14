// Agentz › Settings… (⌘,): the menus' shortcuts, and a few settings the
// menus also have.

import AgentzCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - General

/// What the General tab shows. Read again each time the window comes to
/// the front, since the menus change the same settings.
@MainActor
@Observable
final class GeneralSettings {
    struct Actions {
        var autoHide: () -> Bool
        var setAutoHide: (Bool) -> Void
        var selectTheme: (String?) -> Void
        var notificationSettings: () -> Void
        var statusLine: (_ install: Bool) -> Void
    }

    @ObservationIgnored let actions: Actions
    @ObservationIgnored private let look: Look

    private(set) var autoHide = false
    /// Nil while no terminal runs yet and none was set.
    private(set) var fontSize: Float?
    /// Set here or with ⌘+ / ⌘-, not the Ghostty config's.
    private(set) var ownFontSize = false
    /// Nil to follow the Ghostty config.
    private(set) var theme: String?
    private(set) var lightThemes: [String] = []
    private(set) var darkThemes: [String] = []

    init(look: Look, actions: Actions) {
        self.look = look
        self.actions = actions
    }

    func reload() {
        autoHide = actions.autoHide()
        fontSize = GhosttyApp.fontSize ?? Terminal.fontSize
        ownFontSize = GhosttyApp.fontSize != nil
        look.refreshThemes()
        theme = look.selectedTheme
        let shown = look.themes.filter { !$0.isLookalike || $0.name == theme }
        lightThemes = shown.filter { !$0.isDark }.map(\.name)
        darkThemes = shown.filter(\.isDark).map(\.name)
    }

    func setAutoHide(_ on: Bool) {
        actions.setAutoHide(on)
        reload()
    }

    func changeFontSize(by step: Float) {
        GhosttyApp.changeFontSize(by: step)
        reload()
    }

    func resetFontSize() {
        GhosttyApp.resetFontSize()
        reload()
        // The terminals take the config's size a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reload() }
    }

    func selectTheme(_ name: String?) {
        actions.selectTheme(name)
        reload()
    }
}

struct GeneralSettingsView: View {
    let model: GeneralSettings

    var body: some View {
        let look = Look.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection("Session List") {
                    SettingsRow("Auto-hide the session list",
                                detail: "It slides in when the mouse rests at the window's left edge.") {
                        Toggle("", isOn: Binding(get: { model.autoHide }, set: { model.setAutoHide($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
                SettingsSection("Terminal") {
                    SettingsRow("Font size", detail: model.ownFontSize ? "Set here or with ⌘+ and ⌘-." : "From your Ghostty config.") {
                        HStack(spacing: 6) {
                            Text(model.fontSize.map { String(format: "%g pt", $0) } ?? "—")
                                .font(.system(size: 12))
                                .monospacedDigit()
                            Stepper("Font size", onIncrement: { model.changeFontSize(by: 1) },
                                    onDecrement: { model.changeFontSize(by: -1) })
                                .labelsHidden()
                                .controlSize(.small)
                                .disabled(model.fontSize == nil)
                            Button("Use Ghostty's") { model.resetFontSize() }
                                .buttonStyle(SettingsButtonStyle())
                                .disabled(!model.ownFontSize)
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Theme", detail: "The terminals' colors, and the app's.") {
                        Menu {
                            themeItem(nil)
                            if !model.lightThemes.isEmpty {
                                Section("Light") { ForEach(model.lightThemes, id: \.self) { themeItem($0) } }
                            }
                            if !model.darkThemes.isEmpty {
                                Section("Dark") { ForEach(model.darkThemes, id: \.self) { themeItem($0) } }
                            }
                        } label: {
                            Text(model.theme ?? "Follow Ghostty").font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .tint(look.text)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(look.fieldBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                SettingsSection("Notifications") {
                    SettingsRow("Notifications", detail: "When a session finishes or needs you while you are away.") {
                        Button("Open System Settings…") { model.actions.notificationSettings() }
                            .buttonStyle(SettingsButtonStyle())
                    }
                }
                SettingsSection("Claude Status Line") {
                    SettingsRow("Status line",
                                detail: "Gives agentz Claude's rate limits and context window size from a claude you start by hand.") {
                        HStack(spacing: 6) {
                            Button("Install") { model.actions.statusLine(true) }
                            Button("Uninstall") { model.actions.statusLine(false) }
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(look.background)
    }

    /// A theme in the menu, checked when picked; nil to follow Ghostty.
    private func themeItem(_ name: String?) -> some View {
        Toggle(name ?? "Follow Ghostty", isOn: Binding(get: { model.theme == name }, set: { _ in model.selectTheme(name) }))
    }
}

// MARK: - Look

/// A titled group of rows, like the session list's section labels.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Look.shared.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

/// A setting: its name and what it does on the left, its control on the
/// right.
private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Look.shared.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Look.shared.divider).frame(height: 1).padding(.horizontal, 8)
    }
}

/// A quiet button: the theme's faint fill, a gray one on hover.
private struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsButton(configuration: configuration)
    }

    private struct SettingsButton: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        let configuration: Configuration

        var body: some View {
            let look = Look.shared
            configuration.label
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    configuration.isPressed ? look.selection : hovered ? look.selection.opacity(0.75) : look.fieldBackground,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

// MARK: - Shortcuts

/// Takes the next keys typed, while a shortcut waits for them.
@MainActor
@Observable
final class KeyRecorder {
    /// The entry waiting for keys.
    private(set) var id: String?
    @ObservationIgnored var record: (String, KeyCombo) -> Void = { _, _ in }
    @ObservationIgnored private var monitor: Any?

    func start(_ id: String) {
        stop()
        self.id = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.take(event) ?? false }
            return taken ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        id = nil
    }

    /// ⎋ cancels and ⌫ removes the shortcut. Keys the terminal needs for
    /// typing, without ⌘ or ⌃, beep. The menus never see them.
    private func take(_ event: NSEvent) -> Bool {
        guard let id else { return false }
        let plain = event.modifierFlags.intersection(KeyCombo.usedModifiers).isEmpty
        if plain, event.keyCode == UInt16(kVK_Escape) {
            stop()
        } else if plain, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            record(id, .empty)
            stop()
        } else if let combo = KeyCombo(event: event), combo.isUsable {
            record(id, combo)
            stop()
        } else {
            NSSound.beep()
        }
        return true
    }
}

struct ShortcutsSettingsView: View {
    let bindings: KeyBindings
    let recorder: KeyRecorder
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private struct Group: Identifiable {
        let menu: String
        var entries: [KeyBindings.Entry]
        var id: String { menu }
    }

    private var groups: [Group] {
        let words = search.lowercased().split(separator: " ")
        var groups: [Group] = []
        for entry in bindings.entries {
            let text = "\(entry.menu) \(entry.title) \(bindings.combo(entry.id).text)".lowercased()
            guard words.allSatisfy({ text.contains($0) }) else { continue }
            if groups.last?.menu == entry.menu {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(Group(menu: entry.menu, entries: [entry]))
            }
        }
        return groups
    }

    var body: some View {
        let look = Look.shared
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search", text: $search)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .lookField(isFocused: searchFocused, systemImage: "magnifyingglass")
                Button("Reset All") { bindings.resetAll() }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(bindings.overrides.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(look.divider).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        SettingsSection(group.menu) {
                            ForEach(group.entries) { entry in
                                ShortcutRow(entry: entry, bindings: bindings, recorder: recorder)
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("No command matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(look.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            Rectangle().fill(look.divider).frame(height: 1)
            Text("Click a shortcut and type the new keys. Delete removes it, Esc cancels. "
                + "The keys of the terminal and the lists stay as they are; Help › Keyboard Shortcuts lists them.")
                .font(.system(size: 11))
                .foregroundStyle(look.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(look.background)
        .onDisappear { recorder.stop() }
    }
}

private struct ShortcutRow: View {
    let entry: KeyBindings.Entry
    let bindings: KeyBindings
    let recorder: KeyRecorder
    @State private var hovered = false

    var body: some View {
        let look = Look.shared
        let combo = bindings.combo(entry.id)
        let recording = recorder.id == entry.id
        let warning = bindings.problems[entry.id] ?? bindings.conflict(entry.id)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 12.5))
                if entry.isGlobal {
                    Text("Works in every app. The default comes from your Ghostty config.")
                        .font(.system(size: 11))
                        .foregroundStyle(look.secondary)
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(look.yellow)
                }
            }
            Spacer(minLength: 8)
            if bindings.isChanged(entry.id) {
                iconButton("arrow.uturn.backward",
                           help: entry.defaultCombo.isNone ? "Back to no shortcut" : "Back to \(entry.defaultCombo.text)") {
                    bindings.set(entry.id, nil)
                }
            }
            Button {
                recording ? recorder.stop() : recorder.start(entry.id)
            } label: {
                Text(recording ? "Type keys…" : combo.isNone ? "None" : combo.text)
                    .font(.system(size: 12))
                    .foregroundStyle(recording ? look.accent : combo.isNone ? look.faint : look.text)
                    .frame(minWidth: 92)
                    .frame(height: 22)
                    .background(look.fieldBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(recording ? look.accent.opacity(0.75) : look.divider, lineWidth: recording ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Click and type the new shortcut")
            iconButton("xmark", help: "Remove the shortcut") { bindings.set(entry.id, .empty) }
                .disabled(combo.isNone)
                .opacity(combo.isNone ? 0 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovered ? look.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovered = $0 }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Look.shared.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(GitForkHoverButtonStyle(.icon))
        .help(help)
    }
}

// MARK: - Window

/// Which tab Settings shows.
@MainActor
@Observable
final class SettingsTabs {
    enum Tab: String, CaseIterable {
        case general = "General", shortcuts = "Shortcuts"

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            }
        }
    }

    var tab = Tab.general
}

private struct SettingsView: View {
    let tabs: SettingsTabs
    let general: GeneralSettings
    let bindings: KeyBindings
    let recorder: KeyRecorder

    var body: some View {
        let look = Look.shared
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTabs.Tab.allCases, id: \.self) { tab in
                    Button {
                        tabs.tab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.symbol)
                            .font(.system(size: 12, weight: tabs.tab == tab ? .medium : .regular))
                            .foregroundStyle(tabs.tab == tab ? look.text : look.secondary)
                    }
                    .buttonStyle(GitForkHoverButtonStyle(.row(isSelected: tabs.tab == tab)))
                    .focusEffectDisabled()
                    .fixedSize()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
            Rectangle().fill(look.divider).frame(height: 1)
            switch tabs.tab {
            case .general: GeneralSettingsView(model: general)
            case .shortcuts: ShortcutsSettingsView(bindings: bindings, recorder: recorder)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 600)
        .background(look.background)
        .lookWindowStyle()
        .onChange(of: tabs.tab) { _, _ in recorder.stop() }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let tabs = SettingsTabs()
    private let general: GeneralSettings
    private let recorder = KeyRecorder()

    init(bindings: KeyBindings, general: GeneralSettings) {
        self.general = general
        recorder.record = { [weak bindings] id, combo in bindings?.set(id, combo) }
        let host = NSHostingController(rootView: SettingsView(tabs: tabs, general: general, bindings: bindings, recorder: recorder))
        // This resizable window owns its size.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.setContentSize(NSSize(width: 560, height: 600))
        window.setFrameAutosaveName("agentz.settings")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(_ tab: SettingsTabs.Tab? = nil) {
        if let tab { tabs.tab = tab }
        general.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_: Notification) { general.reload() }
    func windowDidResignKey(_: Notification) { recorder.stop() }
}
