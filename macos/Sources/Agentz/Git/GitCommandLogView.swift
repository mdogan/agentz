import AppKit
import SwiftUI

extension GitCommandKind {
    @MainActor
    var color: Color {
        switch self {
        case .read: GitForkTheme.accent
        case .write: GitForkTheme.orange
        case .delete: GitForkTheme.red
        case .network: GitForkTheme.purple
        }
    }
}

/// Every Git command GitFork ran in the last seven days, newest first and
/// grouped by day, labeled as a read, write, delete, or network command.
/// Background change polling is not recorded.
struct GitCommandLogView: View {
    private let log = GitCommandLog.shared
    @State private var filter = GitCommandLogFilter()
    /// Days before today to show, or `nil` for every day. Kept as an offset so
    /// "Today" still means today after midnight.
    @State private var daysAgo: Int?
    @State private var selection: GitCommandLogEntry.ID?
    @State private var isConfirmingClear = false

    var body: some View {
        let now = Date()
        let calendar = Calendar.current
        let candidates = candidateEntries(now: now, calendar: calendar)
        let visible = candidates.filter { filter.kinds.contains($0.kind) }
        VStack(spacing: 0) {
            filterBar(candidates: candidates, visibleCount: visible.count, now: now, calendar: calendar)

            Divider()

            if visible.isEmpty {
                ContentUnavailableView(
                    log.entries.isEmpty ? "No Git Commands Yet" : "No Matching Commands",
                    systemImage: "terminal",
                    description: Text(
                        log.entries.isEmpty
                            ? "Git commands the panel runs appear here as they finish."
                            : "Change the filters to see more commands."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(daySections(visible, now: now, calendar: calendar), id: \.daysAgo) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        } header: {
                            Text(GitCommandLogDay.title(daysAgo: section.daysAgo, now: now, calendar: calendar))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Look.shared.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .lookListBackground(Look.shared.background)
            }

            if let entry = selectedEntry {
                Divider()
                GitCommandLogDetail(entry: entry)
                    .frame(height: 190)
            }
        }
        .frame(minWidth: 880, minHeight: 420)
        .searchable(text: $filter.searchText, placement: .toolbar, prompt: "Filter commands")
        .toolbar {
            ToolbarItem {
                Button {
                    isConfirmingClear = true
                } label: {
                    Label("Clear Log", systemImage: "clear")
                }
                .disabled(log.entries.isEmpty)
                .instantHelp("Clear the command log")
            }
        }
        .confirmationDialog(
            "Clear the Git command log?",
            isPresented: $isConfirmingClear
        ) {
            Button("Clear Log", role: .destructive) {
                log.clear()
                selection = nil
            }
        } message: {
            Text("This removes all \(log.entries.count) saved commands from the last \(GitCommandLog.retainedDays) days, for every repository.")
        }
        .onAppear {
            log.pruneExpired()
            applyFocusRequest(log.focusRequest)
        }
        .onChange(of: log.focusRequest) { _, request in
            applyFocusRequest(request)
        }
    }

    private func row(_ entry: GitCommandLogEntry) -> some View {
        GitCommandLogRow(
            entry: entry,
            repositoryName: filter.repositoryPath == nil
                ? repositoryName(for: entry)
                : nil
        )
        .tag(entry.id)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(LookListRowBackground(isSelected: entry.id == selection))
        .contextMenu {
            Button("Copy Command") { copy(entry.commandLine) }
            Button("Copy Directory Path") { copy(entry.directory.path) }
        }
    }

    /// Entries, newest first, that pass every filter except the kind filter,
    /// so each kind chip can count what turning it on would show.
    private func candidateEntries(now: Date, calendar: Calendar) -> [GitCommandLogEntry] {
        var other = filter
        other.kinds = Set(GitCommandKind.allCases)
        other.dateRange = daysAgo.map {
            GitCommandLogDay.range(daysAgo: $0, now: now, calendar: calendar)
        }
        return log.entries.reversed().filter { entry in
            other.matches(entry, repositoryPath: log.repositoryPath(for: entry))
        }
    }

    private func daySections(
        _ entries: [GitCommandLogEntry],
        now: Date,
        calendar: Calendar
    ) -> [GitCommandLogDaySection] {
        var sections: [GitCommandLogDaySection] = []
        for entry in entries {
            let daysAgo = GitCommandLogDay.daysAgo(entry.startedAt, now: now, calendar: calendar)
            if sections.last?.daysAgo == daysAgo {
                sections[sections.count - 1].entries.append(entry)
            } else {
                sections.append(GitCommandLogDaySection(daysAgo: daysAgo, entries: [entry]))
            }
        }
        return sections
    }

    private var selectedEntry: GitCommandLogEntry? {
        guard let selection else { return nil }
        return log.entries.first { $0.id == selection }
    }

    private func filterBar(
        candidates: [GitCommandLogEntry],
        visibleCount: Int,
        now: Date,
        calendar: Calendar
    ) -> some View {
        HStack(spacing: 6) {
            repositoryMenu
            dayMenu(now: now, calendar: calendar)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            ForEach(GitCommandKind.allCases) { kind in
                GitCommandLogChip(
                    title: kind.title,
                    systemImage: kind.systemImage,
                    count: candidates.count { $0.kind == kind },
                    color: kind.color,
                    isOn: filter.kinds.contains(kind)
                ) {
                    toggle(kind)
                }
                .help(
                    "Show or hide \(kind.title.lowercased()) commands. "
                        + "Option-click to show only \(kind.title.lowercased()) commands."
                )
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            GitCommandLogChip(
                title: "Failed",
                systemImage: "xmark.octagon",
                count: nil,
                color: GitForkTheme.red,
                isOn: filter.failedOnly
            ) {
                filter.failedOnly.toggle()
            }
            .help("Show only commands that failed")

            Spacer(minLength: 8)

            Text("\(visibleCount) of \(log.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Look.shared.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Look.shared.sidebar)
    }

    private var repositoryMenu: some View {
        GitCommandLogMenu(
            systemImage: "folder",
            title: filter.repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "All Repositories"
        ) {
            Picker("Repository", selection: $filter.repositoryPath) {
                Text("All Repositories").tag(String?.none)
                Divider()
                ForEach(repositoryOptions, id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .tag(String?.some(path))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help("Show commands for one repository")
    }

    private func dayMenu(now: Date, calendar: Calendar) -> some View {
        GitCommandLogMenu(
            systemImage: "calendar",
            title: daysAgo.map { GitCommandLogDay.title(daysAgo: $0, now: now, calendar: calendar) }
                ?? "All Days"
        ) {
            Picker("Day", selection: $daysAgo) {
                Text("All Days").tag(Int?.none)
                Divider()
                ForEach(GitCommandLogDay.offsets, id: \.self) { offset in
                    Text(GitCommandLogDay.title(daysAgo: offset, now: now, calendar: calendar))
                        .tag(Int?.some(offset))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help("Show commands from one day")
    }

    private var repositoryOptions: [String] {
        var paths = log.repositoryRoots
        for entry in log.entries {
            paths.insert(log.repositoryPath(for: entry))
        }
        if let current = filter.repositoryPath {
            paths.insert(current)
        }
        return paths.sorted {
            let lhs = URL(fileURLWithPath: $0).lastPathComponent
            let rhs = URL(fileURLWithPath: $1).lastPathComponent
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func repositoryName(for entry: GitCommandLogEntry) -> String {
        URL(fileURLWithPath: log.repositoryPath(for: entry)).lastPathComponent
    }

    private func toggle(_ kind: GitCommandKind) {
        if NSEvent.modifierFlags.contains(.option) {
            filter.kinds = filter.kinds == [kind] ? Set(GitCommandKind.allCases) : [kind]
        } else if filter.kinds.contains(kind) {
            filter.kinds.remove(kind)
        } else {
            filter.kinds.insert(kind)
        }
    }

    private func applyFocusRequest(_ request: GitCommandLogFocusRequest?) {
        guard let request else { return }
        filter.repositoryPath = request.repositoryPath
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct GitCommandLogDaySection {
    let daysAgo: Int
    var entries: [GitCommandLogEntry]
}

/// A compact pull-down that names its current choice, for the filter bar.
private struct GitCommandLogMenu<Content: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Look.shared.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Look.shared.divider))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(GitForkHoverButtonStyle(.text))
        .fixedSize()
    }
}

/// A toggle drawn as a capsule: filled with its color while on, outlined
/// while off.
private struct GitCommandLogChip: View {
    let title: String
    let systemImage: String
    let count: Int?
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.callout.weight(isOn ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isOn ? color.opacity(0.8) : Look.shared.secondary)
                }
            }
            .foregroundStyle(isOn ? color : Look.shared.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isOn ? color.opacity(0.16) : .clear)
            )
            .overlay(
                Capsule().strokeBorder(isOn ? color.opacity(0.45) : Look.shared.divider)
            )
        }
        .buttonStyle(GitForkHoverButtonStyle(.text))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct GitCommandKindBadge: View {
    let kind: GitCommandKind

    var body: some View {
        Label(kind.title, systemImage: kind.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(width: 84, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(kind.color.opacity(0.14))
            )
    }
}

private struct GitCommandLogRow: View {
    let entry: GitCommandLogEntry
    /// Shown when the log lists several repositories.
    let repositoryName: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(GitCommandLogFormat.time(entry.startedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Look.shared.secondary)

            GitCommandKindBadge(kind: entry.kind)

            Text(entry.commandLine)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let repositoryName {
                Text(repositoryName)
                    .font(.caption)
                    .foregroundStyle(GitForkTheme.repositoryColor(for: repositoryName))
                    .lineLimit(1)
            }

            Text(GitCommandLogFormat.duration(entry.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Look.shared.secondary)
                .frame(width: 58, alignment: .trailing)

            GitCommandOutcomeIcon(outcome: entry.outcome)
                .frame(width: 16)
        }
        .padding(.vertical, 4)
    }
}

private struct GitCommandOutcomeIcon: View {
    let outcome: GitCommandOutcome

    var body: some View {
        switch outcome {
        case .succeeded:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(GitForkTheme.green)
                .help("Succeeded")
        case let .failed(exitCode):
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(GitForkTheme.red)
                .help(GitCommandLogFormat.outcome(.failed(exitCode: exitCode)))
        case .cancelled:
            Image(systemName: "slash.circle")
                .foregroundStyle(Look.shared.secondary)
                .help("Cancelled after it started")
        }
    }
}

private struct GitCommandLogDetail: View {
    let entry: GitCommandLogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.commandLine)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.commandLine, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(GitForkHoverButtonStyle(.icon))
                    .help("Copy the command")
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    detailRow("Kind") { GitCommandKindBadge(kind: entry.kind) }
                    detailRow("Result") { Text(GitCommandLogFormat.outcome(entry.outcome)) }
                    detailRow("Started") {
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    detailRow("Duration") { Text(GitCommandLogFormat.duration(entry.duration)) }
                    detailRow("Directory") {
                        Text(entry.directory.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    detailRow("Output") {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(entry.outputByteCount),
                                countStyle: .file
                            )
                            + (entry.hasInput ? ", with data sent on standard input" : "")
                        )
                    }
                }
                .font(.callout)

                if !entry.errorOutput.isEmpty {
                    Text(entry.errorOutput)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(entry.isFailure ? GitForkTheme.red : Look.shared.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Look.shared.fieldBackground)
                        )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Look.shared.sidebar)
    }

    private func detailRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(Look.shared.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }
}

enum GitCommandLogFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return String(format: "%.2f s", seconds)
    }

    static func outcome(_ outcome: GitCommandOutcome) -> String {
        switch outcome {
        case .succeeded:
            "Succeeded"
        case let .failed(exitCode?):
            "Failed with exit code \(exitCode)"
        case .failed(nil):
            "Failed to start"
        case .cancelled:
            "Cancelled after it started"
        }
    }
}
