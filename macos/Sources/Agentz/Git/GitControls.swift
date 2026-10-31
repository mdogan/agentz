import SwiftUI

/// A toolbar action with a fixed glyph box, so a row of icons keeps an even
/// rhythm no matter how wide each symbol draws.
struct ToolbarIconButton: View {
    let title: String
    let systemImage: String
    let badge: String?
    let help: String
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        badge: String? = nil,
        help: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 21, height: 19)
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(GitForkTheme.accent)
                            .offset(x: 2, y: 2)
                    }
                }
        }
        .buttonStyle(GitForkHoverButtonStyle(.toolbarAction))
        .instantHelp(help)
        .accessibilityLabel(title)
    }
}

/// Separates action clusters inside the single toolbar group.
struct ToolbarSeparator: View {
    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 1, height: 15)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

/// The centered statement of where HEAD is: one glyph, the name, and the
/// distance from its upstream. A detached HEAD reads as a state with the commit
/// it sits on, not as a branch with a sentence for a name.
struct BranchToolbarBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let branch: String
    let ahead: Int
    let behind: Int

    private var head: BranchDisplay { BranchDisplay(branch) }

    private var tint: Color {
        head.isDetached ? GitForkTheme.orange : GitForkTheme.accent
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: head.isDetached ? "circle.dashed" : "arrow.triangle.branch")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(tint)

            switch head {
            case let .branch(name):
                branchName(name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            case let .detached(hash):
                Text("Detached")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                chip(color: tint) {
                    Text(hash)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
            }

            if ahead > 0 {
                trackingChip(count: ahead, systemImage: "arrow.up", color: GitForkTheme.green)
            }
            if behind > 0 {
                trackingChip(count: behind, systemImage: "arrow.down", color: GitForkTheme.blue)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .instantHelp(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(trackingSummary)
    }

    /// De-emphasize the path and keep the most specific branch component easy
    /// to scan, without changing or abbreviating the actual branch name.
    private func branchName(_ name: String) -> Text {
        guard let slash = name.lastIndex(of: "/") else {
            return Text(name)
        }

        let leaf = name.index(after: slash)
        return Text(String(name[...slash]))
            .foregroundColor(.secondary)
            + Text(String(name[leaf...]))
    }

    private func trackingChip(
        count: Int,
        systemImage: String,
        color: Color
    ) -> some View {
        chip(color: color) {
            HStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    /// A chip states a short fact — a hash, a count — so it keeps its ideal
    /// width instead of wrapping to a second line when the toolbar is tight.
    private func chip<Content: View>(
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(color.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
            .layoutPriority(1)
    }

    private var trackingSummary: String {
        var parts: [String] = []
        if ahead > 0 {
            parts.append("\(ahead) ahead")
        }
        if behind > 0 {
            parts.append("\(behind) behind")
        }
        return parts.joined(separator: ", ")
    }

    private var accessibilityLabel: String {
        switch head {
        case let .branch(name): "Current branch \(name)"
        case let .detached(hash): "Detached head at commit \(hash)"
        }
    }

    private var helpText: String {
        let subject: String
        switch head {
        case let .branch(name): subject = "Current branch: \(name)"
        case let .detached(hash): subject = "Detached HEAD at commit \(hash)"
        }

        let status = trackingSummary
        return status.isEmpty ? subject : "\(subject) (\(status))"
    }
}

struct BranchSheet: View {
    @FocusState private var isFieldFocused: Bool
    @EnvironmentObject private var store: RepositoryStore
    @Binding var isPresented: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title)
                    .foregroundStyle(GitForkTheme.accent)
                VStack(alignment: .leading) {
                    Text("Create New Branch")
                        .font(.title2.weight(.semibold))
                    Text("The branch starts at the current HEAD.")
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Branch name", text: $name)
                .focused($isFieldFocused)
                .onSubmit { create() }
                .lookField(isFocused: isFieldFocused)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                Button {
                    create()
                } label: {
                    Label("Create & Checkout", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderedProminent)
                .help("Create the branch at HEAD and check it out")
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isLoading
                )
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func create() {
        store.createBranch(named: name)
        isPresented = false
    }
}

struct RenameBranchSheet: View {
    @FocusState private var isFieldFocused: Bool
    @EnvironmentObject private var store: RepositoryStore
    let reference: GitReference
    @Binding var isPresented: Bool
    @State private var name: String

    init(reference: GitReference, isPresented: Binding<Bool>) {
        self.reference = reference
        _isPresented = isPresented
        _name = State(initialValue: reference.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "pencil")
                    .font(.title)
                    .foregroundStyle(GitForkTheme.accent)
                VStack(alignment: .leading) {
                    Text("Rename Branch")
                        .font(.title2.weight(.semibold))
                    Text(renameDescription)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Branch name", text: $name)
                .focused($isFieldFocused)
                .onSubmit { rename() }
                .lookField(isFocused: isFieldFocused)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                Button {
                    rename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(.borderedProminent)
                .help("Rename the branch and keep its commits and upstream")
                .disabled(!canRename)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var renameDescription: String {
        if reference.upstream == nil {
            return "“\(reference.name)” keeps its commits."
        }
        return "“\(reference.name)” keeps its commits and its upstream."
    }

    private var canRename: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanName.isEmpty && cleanName != reference.name && !store.isLoading
    }

    private func rename() {
        guard canRename else { return }
        store.rename(reference, to: name)
        isPresented = false
    }
}

/// Moves a branch under a prefix typed by the user, which can be new and
/// several levels deep. The sheet shows the resulting name before the rename,
/// so its Move button is the confirmation.
struct MoveBranchToPrefixSheet: View {
    @FocusState private var isFieldFocused: Bool
    @EnvironmentObject private var store: RepositoryStore
    let reference: GitReference
    @Binding var isPresented: Bool
    @State private var prefix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "folder")
                    .font(.title)
                    .foregroundStyle(GitForkTheme.accent)
                VStack(alignment: .leading) {
                    Text("Move to New Prefix")
                        .font(.title2.weight(.semibold))
                    Text("“\(reference.name)” keeps its commits.")
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Prefix, such as experimental/ui", text: $prefix)
                .focused($isFieldFocused)
                .onSubmit { moveBranch() }
                .lookField(isFocused: isFieldFocused)

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(conflict == nil ? Color.secondary : Color.red)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                Button {
                    moveBranch()
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .help("Rename the branch under the new prefix")
                .disabled(!canMove)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var move: GitBranchMove? {
        let cleanPrefix = GitBranchMove.normalizedPrefix(prefix)
        guard !cleanPrefix.isEmpty else { return nil }
        return GitBranchMove(reference: reference, toPrefix: cleanPrefix)
    }

    private var conflict: GitReference? {
        move?.conflictingBranch(in: store.references)
    }

    private var statusMessage: String {
        guard let move else { return "Enter a prefix to see the new branch name." }
        if let conflict {
            return conflict.name == move.newName
                ? "A branch named \(move.newName) already exists."
                : "\(move.newName) is already a folder of branches, such as \(conflict.name)."
        }
        return "New name: \(move.newName)"
    }

    private var canMove: Bool {
        move != nil && conflict == nil && !store.isLoading
    }

    private func moveBranch() {
        guard canMove, let move else { return }
        store.rename(reference, to: move.newName)
        isPresented = false
    }
}

struct StashSheet: View {
    @FocusState private var isFieldFocused: Bool
    @EnvironmentObject private var store: RepositoryStore
    @Binding var isPresented: Bool
    let scope: StashScope
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Stash \(scope.title)", systemImage: "archivebox")
                .font(.title2.weight(.semibold))

            TextField("Message (optional)", text: $message)
                .focused($isFieldFocused)
                .lookField(isFocused: isFieldFocused)

            Text(scope.description)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                Button("Stash") {
                    store.stash(message: message, scope: scope)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .help("Stash \(scope.title.lowercased())")
                .disabled(store.isLoading)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
