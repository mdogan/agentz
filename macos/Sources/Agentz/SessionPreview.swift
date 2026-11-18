import AgentzCore
import SwiftUI

private struct PreviewPage {
    struct Turn: Identifiable {
        /// Count back from the latest turn to keep IDs when older ones load.
        let id: Int
        let prompt: TranscriptMarkdown?
        let reply: TranscriptMarkdown?
    }

    let note: TranscriptMarkdown?
    let turns: [Turn]
    let hasOlder: Bool
}

/// Keep transcript I/O and Markdown parsing off the UI thread.
private actor PreviewReader {
    static let shared = PreviewReader()

    func read(_ key: SessionKey, count: UInt32, note: String?, palette: TranscriptMarkdown.Palette) -> PreviewPage? {
        guard !Task.isCancelled else { return nil }
        let preview = transcriptPreview(key.agent, key.id, count)
        var turns: [PreviewPage.Turn] = []
        let history = preview?.turns ?? []
        for (index, turn) in history.enumerated() {
            guard !Task.isCancelled else { return nil }
            turns.append(.init(id: history.count - index,
                               prompt: turn.prompt.isEmpty ? nil : TranscriptMarkdown(turn.prompt, palette: palette),
                               reply: turn.answer.isEmpty ? nil : TranscriptMarkdown(turn.answer, palette: palette, assistant: key.agent == .codex)))
        }
        return PreviewPage(note: note.map { TranscriptMarkdown($0, palette: palette) }, turns: turns, hasOlder: preview?.hasOlder == true)
    }
}

struct SessionPreview: View {
    let row: Row
    let note: SessionNote?
    @State private var count: UInt32 = 1
    @State private var page: PreviewPage?
    @State private var loading = true

    private struct Request: Equatable {
        let updated: Date
        let count: UInt32
        let note: String?
        let palette: TranscriptMarkdown.Palette
    }

    var body: some View {
        let look = Look.shared
        let request = Request(updated: row.updated, count: count, note: note?.isEmpty == false ? note?.text : nil,
                              palette: .init(text: NSColor(look.text), accent: NSColor(look.accent), code: NSColor(look.magenta)))
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let note = page?.note {
                    message(note, label: "Note", icon: Image(systemName: "note.text"), color: look.magenta, inset: true)
                }
                if page?.hasOlder == true {
                    Button { count += 5 } label: { Label("Show older turns", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.link)
                        .disabled(loading)
                }
                if let page {
                    ForEach(page.turns) { turn in
                        if let prompt = turn.prompt {
                            message(prompt, label: "You", icon: Image(systemName: "person.fill"), color: look.green, inset: true)
                        }
                        if let reply = turn.reply {
                            message(reply, label: row.key.agent.displayName, icon: row.key.agent.icon, color: look.color(for: row.key.agent), inset: false)
                        }
                    }
                }
                if loading { ProgressView().controlSize(.small) }
                else if page?.turns.isEmpty != false {
                    Text("No conversation available.").foregroundStyle(look.secondary)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .tint(look.accent)
        .task(id: request) {
            loading = true
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let result = await PreviewReader.shared.read(row.key, count: request.count, note: request.note, palette: request.palette)
            guard !Task.isCancelled else { return }
            page = result
            loading = false
        }
    }

    private func message(_ document: TranscriptMarkdown, label: String, icon: some View, color: Color, inset: Bool) -> some View {
        let look = Look.shared
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                icon.frame(width: 14)
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            if document.text.length > 0 {
                TranscriptText(text: document.text, linkColor: NSColor(look.accent))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !document.sources.isEmpty {
                DisclosureGroup("Memory sources") {
                    Text(verbatim: document.sources.joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(look.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(inset ? 12 : 0)
        .background(inset ? color.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AttentionListButton<Label: View>: View {
    let workspace: Workspace
    @ViewBuilder var label: () -> Label
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: { label() }
            .buttonStyle(.plain)
            .help("Show sessions that need you (⇧⌘A goes to the next)")
            .popover(isPresented: $presented) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(workspace.attentionKeys, id: \.self) { key in
                            let row = workspace.row(for: key)
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    presented = false
                                    workspace.showAttention(key)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row?.title ?? key.agent.displayName).fontWeight(.semibold)
                                        if case let .waiting(message) = workspace.tabState(key) {
                                            Text(message.isEmpty ? "Waiting for input" : message).lineLimit(3)
                                        } else { Text("Session ended") }
                                        HStack {
                                            Text(row?.place ?? key.agent.displayName)
                                            if let date = workspace.attentionSince[key] {
                                                Text(date, style: .relative)
                                            }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Menu("Snooze") {
                                    ForEach(laterTimes(), id: \.0) { title, date in
                                        Button(title) { workspace.snooze(key, until: date) }
                                    }
                                }.fixedSize()
                            }
                            if key != workspace.attentionKeys.last { Divider() }
                        }
                    }.padding(12)
                }
                .frame(width: 340)
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: true)
            }
    }
}
