import AgentzCore
import AppKit
import SwiftUI

// MARK: - Pop-up button

/// A button that opens a native menu below itself. The menu is built on
/// each click, so it shows what is true at that moment.
struct PopUpButton<Label: View>: View {
    let look: Look
    let help: String
    let menu: () -> NSMenu
    let chevron: Bool
    let label: Label
    @State private var anchor = MenuAnchor()
    @State private var hovered = false

    init(look: Look, help: String, chevron: Bool = true, menu: @escaping () -> NSMenu, @ViewBuilder label: () -> Label) {
        self.look = look
        self.help = help
        self.chevron = chevron
        self.menu = menu
        self.label = label()
    }

    var body: some View {
        Button { anchor.show(menu()) } label: {
            HStack(spacing: 5) {
                label
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(look.secondary)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(hovered ? look.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The AppKit view a menu pops up from.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    func show(_ menu: NSMenu) {
        guard let view else { return }
        let y = view.isFlipped ? view.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        anchor.view = view
    }
}

/// A menu item that runs a closure, with an optional dimmed detail after
/// its title.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, detail: String? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let detail {
            let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            attributedTitle = text
        }
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() { handler() }
}

// MARK: - Recent repos

/// A recent folder, and the worktrees of its repo.
struct RecentRepo {
    /// The folder as the recent folders have it.
    let dir: String
    /// Main first; empty outside a repo.
    let worktrees: [Worktree]

    /// The main checkout, or the folder itself outside a repo.
    var root: String { worktrees.first?.path ?? dir }

    var name: String {
        let name = baseName(root)
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    /// Where it is, e.g. `~/src`.
    var parent: String { tilde((root as NSString).deletingLastPathComponent) }

    var filter: RepoFilter { RepoFilter(name: name, root: root, worktrees: worktrees) }
}

/// The recent folders that still exist, one per repo. Asks git about all
/// of them at once, so a menu of them opens right away.
func recentRepos(_ dirs: [String]) -> [RecentRepo] {
    let dirs = dirs.filter(isDirectory)
    var lists = [[Worktree]](repeating: [], count: dirs.count)
    lists.withUnsafeMutableBufferPointer { out in
        DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
            out[i] = listWorktrees(dirs[i])
        }
    }
    var seen = Set<String>()
    return zip(dirs, lists)
        .map { RecentRepo(dir: $0, worktrees: $1) }
        .filter { seen.insert($0.root).inserted }
}

// MARK: - New worktree

/// Asks for a branch and makes a worktree for it, like `wt`: an existing
/// branch is checked out, a new name becomes a new branch that starts from
/// a worktree.
struct NewWorktreeView: View {
    let worktrees: [Worktree]
    let current: Worktree?
    let created: (NewWorktree) -> Void
    let switchTo: (Worktree) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var branches: [Branch]?
    /// The worktree a new branch starts from, by path.
    @State private var from = ""
    @State private var fromHasChanges = false
    @State private var copyChanges = false
    @State private var error: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    private enum Plan {
        case empty
        case checkout(Branch)
        case busy(Branch, Worktree)
        case fork(String)
    }

    private var main: Worktree? { worktrees.first }
    private var sources: [Worktree] { worktrees.filter { !$0.bare && !$0.missing } }
    private var typed: String { name.trimmingCharacters(in: .whitespaces) }

    private var plan: Plan {
        guard !typed.isEmpty else { return .empty }
        let all = branches ?? []
        let found = all.first { $0.remote == nil && $0.name == typed }
            ?? all.first { $0.ref == typed }
            ?? all.first { $0.name == typed }
        guard let b = found else { return .fork(typed) }
        if b.remote == nil, let wt = worktrees.first(where: { $0.branch == b.name }) {
            return .busy(b, wt)
        }
        return .checkout(b)
    }

    private var canCreate: Bool {
        guard !working, main != nil else { return false }
        switch plan {
        case .checkout: return true
        case .fork: return !from.isEmpty
        case .empty, .busy: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Worktree").font(.headline)
            TextField("Branch", text: $name, prompt: Text("New or existing branch"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)
            branchList
            details
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            from = (current.flatMap { wt in sources.first { $0 == wt } } ?? sources.first)?.path ?? ""
            nameFocused = true
        }
        .task {
            guard let dir = main?.path else { return }
            branches = await Task.detached { (try? gitBranches(dir)) ?? [] }.value
        }
        .task(id: from) {
            guard !from.isEmpty else { return }
            let dir = from
            fromHasChanges = await Task.detached { worktreeHasChanges(dir) }.value
        }
    }

    private var matches: [Branch] {
        let q = typed.lowercased()
        let all = branches ?? []
        return q.isEmpty ? all : all.filter { $0.ref.lowercased().contains(q) }
    }

    /// Existing branches that match what was typed. Click one to use it,
    /// double-click to create its worktree right away.
    private var branchList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.ref) { b in
                    let busy = b.remote == nil ? worktrees.first { $0.branch == b.name } : nil
                    let picked = typed == pickName(b)
                    HStack(spacing: 6) {
                        Image(systemName: b.remote == nil ? "arrow.triangle.branch" : "cloud")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(b.ref).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let busy {
                            Text("in \(baseName(busy.path))").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(picked ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        name = pickName(b)
                        create()
                    }
                    .simultaneousGesture(TapGesture().onEnded { name = pickName(b) })
                }
            }
            .padding(4)
        }
        .frame(height: 150)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .overlay {
            if branches == nil {
                ProgressView().controlSize(.small)
            } else if matches.isEmpty {
                Text(typed.isEmpty ? "No branches" : "No branch matches. Create adds it as a new branch.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pickName(_ b: Branch) -> String {
        b.remote == nil ? b.name : b.ref
    }

    @ViewBuilder
    private var details: some View {
        switch plan {
        case .empty:
            Text("Type a name for a new branch, or pick an existing one.")
                .foregroundStyle(.secondary)
        case let .checkout(b):
            if b.remote == nil {
                Text("Checks out **\(b.name)** in a new worktree.")
            } else {
                Text("Checks out **\(b.ref)** as the new local branch **\(b.name)**.")
            }
            location(branch: b.name, copyFrom: main)
        case let .busy(b, wt):
            HStack(alignment: .firstTextBaseline) {
                Text("**\(b.name)** is already checked out in \(tilde(wt.path)).")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Switch to It") {
                    switchTo(wt)
                    dismiss()
                }
            }
        case let .fork(branch):
            Picker("Start **\(branch)** from", selection: $from) {
                ForEach(sources, id: \.path) { wt in
                    Text("\(wt.label) — \(baseName(wt.path))").tag(wt.path)
                }
            }
            Toggle("Copy uncommitted changes too", isOn: $copyChanges)
                .disabled(!fromHasChanges)
                .help(fromHasChanges
                    ? "Staged changes stay staged. The worktree it starts from is not changed."
                    : "That worktree has no uncommitted changes.")
            location(branch: branch, copyFrom: sources.first { $0.path == from })
        }
    }

    /// Where the worktree goes, and what gets copied into it.
    @ViewBuilder
    private func location(branch: String, copyFrom: Worktree?) -> some View {
        if let main {
            VStack(alignment: .leading, spacing: 3) {
                Text("Folder: \(tilde(newWorktreePath(main.path, branch)))")
                if let copyFrom, !copyFrom.bare {
                    Text("Ignored files like .env and node_modules are copied from \(baseName(copyFrom.path)).")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func create() {
        guard canCreate else { return }
        let job: @Sendable () throws -> NewWorktree
        switch plan {
        case let .checkout(b):
            let dir = main?.path ?? "", ref = b.ref
            job = { try addWorktree(dir, ref) }
        case let .fork(branch):
            let dir = from, changes = copyChanges && fromHasChanges
            job = { try forkWorktree(dir, branch, changes) }
        case .empty, .busy:
            return
        }
        working = true
        error = nil
        Task {
            let result = await Task.detached { Result { try job() } }.value
            working = false
            switch result {
            case let .success(made):
                created(made)
                dismiss()
            case let .failure(e):
                error = errorMessage(e)
            }
        }
    }
}
