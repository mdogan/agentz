import AgentzCore
import AppKit
import SwiftUI

// MARK: - Places

/// What the user picked in `StartPicker`.
enum StartChoice {
    /// Start in `dir`. `repo` is the recent folder it is listed under,
    /// which becomes the most recent one.
    case folder(dir: String, repo: String)
    case newWorktree(RecentRepo)
    case openFolder
    case createFolder
}

/// A row of `StartPicker`.
struct StartPlace: Identifiable {
    let id: String
    let choice: StartChoice
    let title: String
    /// Dimmed after the title: the branch of a repo's main checkout.
    var branch: String?
    /// Dimmed at the right, e.g. `~/src`.
    var detail = ""
    let icon: String
    /// Under its repo, like a linked worktree.
    var indented = false
    /// Shown whatever the filter, like Open Folder….
    var always = false
    /// What the filter looks in, lowercased.
    let words: String

    /// True if each of `query`'s lowercased words is in it.
    func matches(_ query: [Substring]) -> Bool {
        query.allSatisfy { words.contains($0) }
    }
}

/// The rows of `StartPicker`: the recent folders, and in a repo each of its
/// worktrees and a row that makes a new one, then rows that ask for another
/// folder. The repo or folder `here` is in comes first. `picked` is the row
/// of `here` itself; a folder that is no worktree, like `src` in a repo,
/// gets a row of its own on top.
func startPlaces(here: String, recents: [String]) -> (places: [StartPlace], picked: String?) {
    // `here` last, so that a recent folder of the same repo stands for it.
    var repos = recentRepos(recents + [here])
    let hereRepo = repoIndex(containing: here, in: repos)
    if let i = hereRepo {
        repos.insert(repos.remove(at: i), at: 0)
    }
    var places: [StartPlace] = []
    var picked: String?
    for repo in repos {
        guard !repo.worktrees.isEmpty else {
            places.append(folderPlace(repo.dir, repo: repo.dir))
            if samePath(repo.dir, here) { picked = repo.dir }
            continue
        }
        for wt in repo.worktrees where !wt.bare && !wt.missing {
            let path = tilde(wt.path)
            places.append(StartPlace(
                id: wt.path,
                choice: .folder(dir: wt.path, repo: repo.dir),
                title: wt.isMain ? repo.name : wt.label,
                branch: wt.isMain ? wt.label : nil,
                detail: wt.isMain ? repo.parent : path,
                icon: wt.isMain ? "folder" : "arrow.triangle.branch",
                indented: !wt.isMain,
                words: "\(repo.name) \(wt.label) \(path)".lowercased()
            ))
            if samePath(wt.path, here) { picked = wt.path }
        }
        places.append(StartPlace(
            id: "new-worktree:" + repo.root,
            choice: .newWorktree(repo),
            title: "New Worktree…",
            icon: "plus",
            indented: true,
            words: "\(repo.name) new worktree".lowercased()
        ))
    }
    if picked == nil, isDirectory(here) {
        places.insert(folderPlace(here, repo: hereRepo == nil ? here : repos[0].dir), at: 0)
        picked = here
    }
    places.append(StartPlace(id: "open", choice: .openFolder, title: "Open Folder…", icon: "ellipsis.circle", always: true, words: "open folder"))
    places.append(StartPlace(
        id: "create", choice: .createFolder, title: "Create Folder…", icon: "folder.badge.plus", always: true, words: "create folder"
    ))
    return (places, picked)
}

private func folderPlace(_ dir: String, repo: String) -> StartPlace {
    let parent = tilde((dir as NSString).deletingLastPathComponent)
    return StartPlace(
        id: dir,
        choice: .folder(dir: dir, repo: repo),
        title: baseName(dir),
        detail: parent,
        icon: "folder",
        words: "\(baseName(dir)) \(parent)".lowercased()
    )
}

/// The repo or folder `dir` is in, the deepest one if they nest.
private func repoIndex(containing dir: String, in repos: [RecentRepo]) -> Int? {
    let tops = repos.enumerated().compactMap { i, repo -> (Int, String)? in
        let top = repo.worktrees.isEmpty
            ? (pathStarts(dir, with: repo.root) || pathStarts(realPath(dir) ?? dir, with: repo.root) ? repo.root : nil)
            : worktree(containing: dir, in: repo.worktrees)?.path
        return top.map { (i, $0) }
    }
    return tops.max { $0.1.count < $1.1.count }?.0
}

private func samePath(_ a: String, _ b: String) -> Bool {
    a == b || (realPath(a) ?? a) == (realPath(b) ?? b)
}

// MARK: - Picker

/// Asks where to start a new session: ⌘N, ⇧⌘N and ⌘T. Typing narrows the
/// list, ↑ and ↓ pick a row, ↩ starts there and ⎋ closes it.
struct StartPicker: View {
    let agent: Agent
    let places: [StartPlace]
    /// The row picked at first.
    let picked: String?
    let close: () -> Void
    let choose: (StartChoice) -> Void
    @State private var query = ""
    @State private var selection: String?
    /// ↩ may reach both the field and the Start button.
    @State private var done = false

    private static let rowHeight: CGFloat = 24

    private var words: [Substring] {
        query.lowercased().split(whereSeparator: \.isWhitespace)
    }

    private var shown: [StartPlace] {
        let words = words
        return words.isEmpty ? places : places.filter { $0.always || $0.matches(words) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(agent == .shell ? "New Shell" : "New \(agent.displayName) Session").font(.headline)
            // The field keeps the keyboard while the sheet shows.
            PickerField(text: $query, prompt: "Folder, repo or branch", move: move, submit: submit, cancel: cancel)
                .lookField(isFocused: true, systemImage: "magnifyingglass")
            list
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selection = picked ?? places.first?.id }
        .onChange(of: query) {
            let words = words
            selection = words.isEmpty
                ? picked ?? places.first?.id
                : (shown.first { $0.matches(words) } ?? shown.first)?.id
        }
    }

    private var list: some View {
        let shown = shown
        let firstAlways = shown.first(where: \.always)?.id
        // As high as all rows, up to a point, and the same while filtering.
        let height = min(CGFloat(places.count) * Self.rowHeight + 17, 360)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { place in
                        if place.id == firstAlways, place.id != shown.first?.id {
                            Divider().padding(.vertical, 4)
                        }
                        row(place).id(place.id)
                    }
                }
                .padding(4)
            }
            .frame(height: height)
            .background(Look.shared.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Look.shared.divider))
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ place: StartPlace) -> some View {
        let look = Look.shared
        let selected = place.id == selection
        return HStack(spacing: 6) {
            Image(systemName: place.icon)
                .foregroundStyle(look.secondary)
                .frame(width: 16)
            Text(place.title)
                .lineLimit(1)
                .layoutPriority(1)
            if let branch = place.branch {
                Text(branch).foregroundStyle(look.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(place.detail)
                .foregroundStyle(look.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(look.text)
        .padding(.leading, place.indented ? 26 : 6)
        .padding(.trailing, 6)
        .frame(height: Self.rowHeight)
        .background(selected ? look.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = place.id
            submit()
        }
        .help(place.detail)
    }

    private func move(_ delta: Int) {
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return }
        let at = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[min(max(at + delta, 0), ids.count - 1)]
    }

    private func submit() {
        guard !done, let place = shown.first(where: { $0.id == selection }) else { return }
        done = true
        choose(place.choice)
    }

    private func cancel() {
        guard !done else { return }
        done = true
        close()
    }
}

/// The picker's filter. ↑ and ↓ move in the list, ↩ submits and ⎋ closes,
/// while the keyboard stays in the field.
struct PickerField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FirstField(string: text)
        field.placeholderString = prompt
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setAccessibilityLabel(prompt)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.field = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = NSColor(Look.shared.colors.foreground)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: PickerField

        init(_ field: PickerField) {
            self.field = field
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            field.text = view.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                field.move(-1)
            case #selector(NSResponder.moveDown(_:)):
                field.move(1)
            case #selector(NSResponder.insertNewline(_:)):
                field.submit()
            case #selector(NSResponder.cancelOperation(_:)):
                field.cancel()
            default:
                return false
            }
            return true
        }
    }
}

/// Takes the keyboard once it is in a window.
private final class FirstField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
