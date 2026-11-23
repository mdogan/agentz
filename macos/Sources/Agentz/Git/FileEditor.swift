import AgentzCore
import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

// Editing a changed file in place, in the Changes view. The editor is
// CodeEditSourceEditor: tree-sitter highlighting, find, and the completion
// popup that `WordCompletion` fills.
//
// Agents write the same files while they are open here, so the file on
// disk is watched: an unedited file follows it, and edited text is never
// saved over a change the user has not seen.

/// What a file on disk holds, for the editor.
enum EditableText: Equatable {
    case text(String)
    case missing
    case unavailable(String)

    /// Larger files are left to a real editor.
    static let maxBytes = 4 << 20

    static func decode(_ data: Data) -> EditableText {
        if data.count > maxBytes { return .unavailable("This file is too large to edit here.") }
        if data.prefix(8000).contains(0) { return .unavailable("This is a binary file.") }
        guard String(data: data, encoding: .utf8) != nil else {
            return .unavailable("This file is not UTF-8 text.")
        }
        // Keeps a byte order mark as U+FEFF, so saving writes it back.
        return .text(String(decoding: data, as: UTF8.self))
    }

    static func read(_ url: URL) -> EditableText {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return .missing }
        if isFolder.boolValue { return .unavailable("This is a folder.") }
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            return .unavailable("This file is too large to edit here.")
        }
        do {
            return decode(try Data(contentsOf: url))
        } catch {
            return fm.fileExists(atPath: url.path) ? .unavailable(error.localizedDescription) : .missing
        }
    }

    /// Tabs, or spaces in twos or fours, as most of the file's indented
    /// lines have them.
    static func indent(for text: String) -> IndentOption {
        var tabs = 0, spaced = 0, byTwo = 0
        // `isNewline` takes "\r\n", one Character, as a line break too.
        for line in text.split(whereSeparator: \.isNewline).prefix(2000) {
            if line.first == "\t" {
                tabs += 1
                continue
            }
            let n = line.prefix { $0 == " " }.count
            guard n > 0, n < line.count else { continue }
            spaced += 1
            if n % 4 == 2 { byTwo += 1 }
        }
        if tabs > spaced { return .tab }
        // In code indented by four, lines at two are rare alignments.
        return .spaces(count: byTwo * 5 > spaced ? 2 : 4)
    }

    /// The file a change edits, when there is one to edit: conflicts have
    /// their own view, and a deleted file has nothing on disk. A symbolic
    /// link is left out: git tracks the link itself, not what it points to.
    static func url(root: URL?, change: WorkingChange) -> URL? {
        guard let root, !change.isConflicted else { return nil }
        let url = root.appendingPathComponent(change.path)
        // Does not follow a link in the last part of the path.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeRegular ? url : nil
    }

    /// Whether two texts are the same bytes. Swift's `==` takes "é" and
    /// "e" with a combining accent as equal; git and the disk do not.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        // Different UTF-16 lengths are different bytes; checking that first
        // is quick for the editor's text, which is an NSString.
        guard (a as NSString).length == (b as NSString).length else { return false }
        return a.utf8.elementsEqual(b.utf8)
    }
}

/// One file open in the editor.
@MainActor
final class FileEditorModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case unavailable(String)
    }

    enum DiskChange: Equatable {
        case modified
        case deleted
    }

    let url: URL
    /// As the Changes list shows it.
    let path: String
    @Published private(set) var phase = Phase.ready
    @Published private(set) var isDirty = false
    /// Set when the file changed on disk while it had unsaved edits here.
    @Published private(set) var diskChange: DiskChange?
    /// A new editor view for each new text from disk.
    @Published private(set) var generation = 0
    @Published var errorMessage: String?

    private(set) var text = ""
    /// The file as last read or written; nil once the user chose to keep
    /// their text for a file that was deleted.
    private var baseline: String?
    var state = SourceEditorState()
    private(set) var language = CodeLanguage.default
    private(set) var indent = IndentOption.spaces(count: 4)
    let completion: WordCompletion
    let bridge = EditorBridge()
    private var watcher: FolderWatcher?
    /// For tests: runs after a save has checked the file and before it
    /// replaces it, where another writer could still come in.
    var beforeReplace: (() -> Void)?

    private static let live = NSHashTable<FileEditorModel>.weakObjects()

    init(url: URL, path: String, otherFiles: [URL] = []) {
        self.url = url.standardizedFileURL
        self.path = path
        completion = WordCompletion(otherFiles: otherFiles)
        bridge.onChange = { [weak self] text in self?.textDidChange(text) }
        adopt(EditableText.read(self.url))
        watch()
        Self.live.add(self)
    }

    /// The editor holding the keyboard focus in `window`, for ⌘S.
    static func focused(in window: NSWindow?) -> FileEditorModel? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return live.allObjects.first { model in
            model.bridge.controller.map { responder.isDescendant(of: $0.view) } ?? false
        }
    }

    /// The open editor for a path as the Changes list shows it.
    static func open(path: String) -> FileEditorModel? {
        live.allObjects.first { $0.path == path }
    }

    /// Saves every open editor that can be saved. Returns the paths of the
    /// ones that still hold unsaved text, such as one an agent changed.
    @discardableResult
    static func saveAll() -> [String] {
        live.allObjects.compactMap { model in
            model.saveIfPossible()
            return model.isDirty ? model.path : nil
        }
    }

    func textDidChange(_ text: String) {
        self.text = text
        let dirty = !EditableText.same(text, baseline)
        if dirty != isDirty { isDirty = dirty }
    }

    /// Writes the text, unless the file changed on disk since it was read:
    /// then it shows that instead, for the user to choose.
    @discardableResult
    func save() -> Bool {
        guard phase == .ready else { return false }
        guard isDirty else { return true }
        // A change already on disk shows without touching the file.
        guard matchesDisk() else { return false }
        do {
            guard try replace(expecting: baseline) else {
                _ = matchesDisk()
                if diskChange == nil { diskChange = .modified }
                return false
            }
            baseline = text
            isDirty = false
            diskChange = nil
            return true
        } catch {
            errorMessage = "Could not save \(path): \(error.localizedDescription)"
            return false
        }
    }

    /// Whether the file still holds what the editor read, or already holds
    /// the editor's text. If not, it shows that the file changed.
    private func matchesDisk() -> Bool {
        let disk = EditableText.read(url)
        let unchanged = switch disk {
        case .text(let s): EditableText.same(s, baseline) || EditableText.same(s, text)
        case .missing: baseline == nil
        case .unavailable: false
        }
        if !unchanged { diskChange = disk == .missing ? .deleted : .modified }
        return unchanged
    }

    /// When the editor goes away: keeps the edits on disk, unless that
    /// would write over a change from outside.
    func saveIfPossible() {
        if isDirty, diskChange == nil { save() }
    }

    /// Drops the edits for what is on disk.
    func reloadFromDisk() {
        adopt(EditableText.read(url))
    }

    /// Keeps the edits; the next save writes them over the change on disk.
    func keepMine() {
        switch EditableText.read(url) {
        case .text(let s): baseline = s
        case .missing: baseline = nil
        case .unavailable: return
        }
        diskChange = nil
        isDirty = !EditableText.same(text, baseline)
    }

    func diskDidChange() {
        let disk = EditableText.read(url)
        guard phase == .ready else {
            if case .text = disk { adopt(disk) }
            return
        }
        switch disk {
        case .text(let s):
            if EditableText.same(s, baseline) {
                if diskChange != nil { diskChange = nil }
            } else if !isDirty || EditableText.same(s, text) {
                adopt(disk)
            } else if diskChange != .modified {
                diskChange = .modified
            }
        case .missing:
            guard baseline != nil else { return }
            if isDirty {
                if diskChange != .deleted { diskChange = .deleted }
            } else {
                phase = .unavailable("This file was deleted.")
            }
        case .unavailable(let why):
            if isDirty {
                if diskChange != .modified { diskChange = .modified }
            } else {
                phase = .unavailable(why)
            }
        }
    }

    private func adopt(_ disk: EditableText) {
        switch disk {
        case .text(let s):
            if generation == 0 {
                language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(s.prefix(256)))
                indent = EditableText.indent(for: s)
            }
            text = s
            baseline = s
            // The cursors stay where they were, inside the new text.
            let length = (s as NSString).length
            state.cursorPositions = state.cursorPositions?.map {
                CursorPosition(range: NSRange(location: min(max($0.range.location, 0), length), length: 0))
            }
            phase = .ready
            generation += 1
        case .missing:
            phase = .unavailable("This file is not on disk.")
        case .unavailable(let why):
            phase = .unavailable(why)
        }
        isDirty = false
        diskChange = nil
    }

    /// Puts the text in the file only if the file holds `expected` (nil:
    /// no file) right then; returns false when another writer came first.
    ///
    /// The text goes to a new file next to it, which then swaps places with
    /// the file in one step. What comes out of the swap is exactly what was
    /// replaced: if that is not `expected`, it is swapped back.
    private func replace(expecting expected: String?) throws -> Bool {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).agentz-\(UUID().uuidString.prefix(8))")
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "It is now a symbolic link."])
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: temp)
        defer { try? fm.removeItem(at: temp) }
        // Keep the file's mode, such as the executable bit.
        if let mode = attributes?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        }
        beforeReplace?()

        guard let expected else {
            // The file was deleted; put it back only if nobody made a new one.
            if renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 { return true }
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard renamex_np(temp.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let replaced = try? Data(contentsOf: temp)
        if replaced == Data(expected.utf8) || replaced == Data(text.utf8) { return true }
        // Another writer came in between: theirs goes back.
        _ = renamex_np(temp.path, url.path, UInt32(RENAME_SWAP))
        return false
    }

    private func watch() {
        let folder = url.deletingLastPathComponent().path
        let file = (realPath(folder) ?? folder) + "/" + url.lastPathComponent
        watcher = FolderWatcher([folder], ignoring: [], fileEvents: true) { [weak self] paths in
            guard paths?.contains(file) ?? true else { return }
            MainActor.assumeIsolated { self?.diskDidChange() }
        }
    }
}

/// Hands the editor's controller and its text changes to the model.
final class EditorBridge: TextViewCoordinator {
    weak var controller: TextViewController?
    var onChange: ((String) -> Void)?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }

    func textViewDidChangeText(controller: TextViewController) {
        onChange?(controller.text)
    }

    // No `destroy()`: a reload makes the new controller before the old one
    // goes, and `controller` is weak anyway.
}

/// The open editors of one git view. A file's editor stays while it has
/// unsaved text, so going to another file and back keeps it.
@MainActor
final class FileEditors: ObservableObject {
    private var models: [String: FileEditorModel] = [:]

    func model(for url: URL, path: String, otherFiles: @autoclosure () -> [URL]) -> FileEditorModel {
        let key = url.standardizedFileURL.path
        if let model = models[key] { return model }
        models = models.filter { $0.value.isDirty }
        let model = FileEditorModel(url: url, path: path, otherFiles: otherFiles())
        models[key] = model
        return model
    }

    /// The editor holding unsaved text for a path, even when the file is
    /// gone from disk, so its bar can still offer to keep the text.
    func draft(path: String) -> FileEditorModel? {
        models.values.first { $0.path == path && $0.isDirty }
    }

    /// Saves what can be saved. Returns the paths still holding unsaved
    /// text, such as files an agent changed under the edits.
    func saveAll() -> [String] {
        models.values.compactMap { model in
            model.saveIfPossible()
            return model.isDirty ? model.path : nil
        }
        .sorted()
    }
}

struct FileEditorView: View {
    @ObservedObject var model: FileEditorModel
    /// The change on screen is the staged one; the editor still edits the
    /// working copy.
    let staged: Bool

    var body: some View {
        let look = Look.shared
        VStack(spacing: 0) {
            if let change = model.diskChange {
                DiskChangeBar(change: change, model: model)
            } else if staged {
                EditorNote(text: "Editing the working copy. The staged version stays as it is.")
            }
            switch model.phase {
            case .unavailable(let why):
                GitPlaceholder(why)
            case .ready:
                SourceEditor(
                    Binding(get: { model.text }, set: { _ in }),
                    language: model.language,
                    configuration: configuration(look),
                    state: Binding(get: { model.state }, set: { model.state = $0 }),
                    coordinators: [model.bridge],
                    completionDelegate: model.completion
                )
                .id(model.generation)
            }
        }
        .background(look.background)
        .onDisappear { model.saveIfPossible() }
        .alert(
            "Could Not Save",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func configuration(_ look: Look) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: .agentz(look),
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                lineHeightMultiple: 1.3,
                wrapLines: true,
                tabWidth: 4,
                bracketPairEmphasis: .flash
            ),
            behavior: .init(indentOption: model.indent),
            layout: .init(editorOverscroll: 0.3),
            peripherals: .init(showMinimap: false, showFoldingRibbon: false)
        )
    }
}

private struct DiskChangeBar: View {
    let change: FileEditorModel.DiskChange
    let model: FileEditorModel

    var body: some View {
        let look = Look.shared
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(look.yellow)
            Text(change == .deleted
                ? "This file was deleted on disk. Your edits are not saved."
                : "This file changed on disk. Your edits are not saved.")
                .font(.system(size: 11.5))
                .foregroundStyle(look.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(change == .deleted ? "Discard Mine" : "Reload") { model.reloadFromDisk() }
                .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
                .help(change == .deleted
                    ? "Drop your edits; the file stays deleted"
                    : "Drop your edits and show the file as it is on disk")
            Button("Keep Mine") { model.keepMine() }
                .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
                .help("Keep your edits; saving writes them over the file on disk")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(look.yellow.opacity(0.12))
    }
}

private struct EditorNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Look.shared.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Look.shared.fieldBackground)
    }
}

/// Save button for the change header: shows whether there is anything to save.
struct EditorSaveButton: View {
    @ObservedObject var model: FileEditorModel

    var body: some View {
        Button {
            model.save()
        } label: {
            Text(model.isDirty ? "Save" : "Saved")
                .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
        .background(Look.shared.fieldBackground, in: RoundedRectangle(cornerRadius: 5))
        .help("Write your edits to the file (⌘S)")
        .disabled(!model.isDirty || model.phase != .ready)
    }
}

extension EditorTheme {
    /// The terminal theme's colors, as the rest of the git views use them.
    @MainActor
    static func agentz(_ look: Look) -> EditorTheme {
        let c = look.colors
        let fg = NSColor(c.foreground)
        let bg = NSColor(c.background)
        func ansi(_ color: Color) -> NSColor { NSColor(color) }
        let comment = NSColor(c.background.mixed(with: c.foreground, 0.5))
        return EditorTheme(
            text: .init(color: fg),
            insertionPoint: c.cursor.map(NSColor.init) ?? fg,
            invisibles: .init(color: NSColor(c.background.mixed(with: c.foreground, 0.25))),
            background: bg,
            lineHighlight: NSColor(c.background.mixed(with: c.foreground, look.isDark ? 0.05 : 0.04)),
            selection: NSColor(c.selection ?? c.background.mixed(with: c.foreground, 0.2)),
            keywords: .init(color: ansi(look.magenta)),
            commands: .init(color: ansi(look.accent)),
            types: .init(color: ansi(look.cyan)),
            attributes: .init(color: ansi(look.yellow)),
            variables: .init(color: fg),
            values: .init(color: ansi(look.yellow)),
            numbers: .init(color: ansi(look.yellow)),
            strings: .init(color: ansi(look.green)),
            characters: .init(color: ansi(look.green)),
            comments: .init(color: comment, italic: true)
        )
    }
}
