import AgentzCore
import SwiftUI

/// Rapid keyboard navigation can queue several selections. Only the visible
/// preview needs I/O. Finish any in-flight read before starting the next.
private actor PreviewReader {
    static let shared = PreviewReader()

    func read(_ key: SessionKey, count: UInt32) -> TranscriptPreview? {
        guard !Task.isCancelled else { return nil }
        return transcriptPreview(key.agent, key.id, count)
    }
}

struct SessionPreview: View {
    let row: Row
    let note: SessionNote?
    @State private var count: UInt32 = 1
    @State private var preview: TranscriptPreview?
    @State private var finished = false

    private struct Request: Equatable {
        let updated: Date
        let count: UInt32
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let note, !note.isEmpty { section("Note", note.text) }
                if preview?.hasOlder == true {
                    Button("Show older turns") { count += 5 }
                }
                if let preview {
                    ForEach(Array(preview.turns.enumerated()), id: \.offset) { _, turn in
                        if !turn.prompt.isEmpty { section("You", turn.prompt) }
                        if !turn.answer.isEmpty { section(row.key.agent.displayName, turn.answer) }
                    }
                }
                if !finished { ProgressView().controlSize(.small) }
                else if preview?.turns.isEmpty != false {
                    Text("No conversation available.").foregroundStyle(Look.shared.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: Request(updated: row.updated, count: count)) {
            finished = false
            let key = row.key, limit = count
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let result = await PreviewReader.shared.read(key, count: limit)
            guard !Task.isCancelled else { return }
            preview = result
            finished = true
        }
    }

    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Look.shared.secondary)
            Text(verbatim: text).textSelection(.enabled)
        }
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
