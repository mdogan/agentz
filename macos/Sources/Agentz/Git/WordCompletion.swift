import AppKit
import CodeEditSourceEditor
import SwiftUI

/// Completion from the words already written: in the open file, and in the
/// other changed files. Works for every language, with no language server.
enum WordIndex {
    /// A word starts with a letter or `_`, and is at least three long.
    private static let pattern = try! NSRegularExpression(pattern: "[\\p{L}_][\\p{L}\\p{N}_]{2,63}")
    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return wordCharacters.contains(scalar)
    }

    /// Where the word that ends at `location` starts.
    static func wordStart(in text: NSString, before location: Int) -> Int {
        var start = min(location, text.length)
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    /// Where the word that goes on from `location` ends.
    static func wordEnd(in text: NSString, after location: Int) -> Int {
        var end = min(location, text.length)
        while end < text.length, isWordUnit(text.character(at: end)) { end += 1 }
        return end
    }

    /// How often each word is in `text`.
    static func counts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let ns = text as NSString
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range else { return }
            counts[ns.substring(with: range), default: 0] += 1
        }
        return counts
    }

    /// The words that go on from `prefix`, best first: the same case, then
    /// the most used, then the shortest.
    static func ranked(_ counts: [String: Int], prefix: String, limit: Int = 50) -> [String] {
        let lower = prefix.lowercased()
        let length = prefix.count
        let matches = counts.keys.filter { $0.count > length && $0.lowercased().hasPrefix(lower) }
        return matches.sorted { a, b in
            let aCase = a.hasPrefix(prefix), bCase = b.hasPrefix(prefix)
            if aCase != bCase { return aCase }
            let aCount = counts[a] ?? 0, bCount = counts[b] ?? 0
            if aCount != bCount { return aCount > bCount }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
        .prefix(limit)
        .map { $0 }
    }
}

@MainActor
final class WordCompletion: CodeSuggestionDelegate {
    final class Item: CodeSuggestionEntry {
        let label: String
        let detail: String?
        var documentation: String? { nil }
        var pathComponents: [String]? { nil }
        var targetPosition: CursorPosition? { nil }
        var sourcePreview: String? { nil }
        var image: Image { Image(systemName: "textformat.abc") }
        var imageColor: Color { .secondary }
        var deprecated: Bool { false }

        init(label: String, detail: String?) {
            self.label = label
            self.detail = detail
        }
    }

    /// Words of the other changed files, and the file each is from.
    private struct Others: Sendable {
        var counts: [String: Int] = [:]
        var sources: [String: String] = [:]
    }

    private static let minimumPrefix = 2
    private let otherFiles: [URL]
    private var others: Task<Others, Never>?
    private var counts: [String: Int] = [:]
    private var sources: [String: String] = [:]
    /// The editor shows no window for an empty list, and has no call for
    /// when its window closes; this keeps track of whether it is open.
    private var isShowing = false
    /// Right after a completion, the word typed is whole; asking again
    /// would offer longer words at once.
    private var completedAt: Int?

    init(otherFiles: [URL]) {
        self.otherFiles = otherFiles
    }

    private func otherWords() async -> Others {
        if others == nil {
            let urls = otherFiles
            others = Task.detached(priority: .utility) {
                var result = Others()
                for url in urls.prefix(200) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                    guard size <= 512 << 10, let data = try? Data(contentsOf: url),
                          case .text(let text) = EditableText.decode(data) else { continue }
                    for (word, count) in WordIndex.counts(in: text) {
                        result.counts[word, default: 0] += count
                        if result.sources[word] == nil { result.sources[word] = url.lastPathComponent }
                    }
                }
                return result
            }
        }
        return await others!.value
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        isShowing = false
        let text = textView.text as NSString
        let location = cursorPosition.range.location
        guard location != NSNotFound, location <= text.length else { return nil }
        if completedAt == location {
            completedAt = nil
            return nil
        }
        completedAt = nil
        let start = WordIndex.wordStart(in: text, before: location)
        guard location - start >= Self.minimumPrefix, !isDigit(text.character(at: start)) else { return nil }

        // The word being typed is left out, so it does not offer itself.
        let end = WordIndex.wordEnd(in: text, after: location)
        let rest = text.replacingCharacters(in: NSRange(location: start, length: end - start), with: " ")
        let others = await otherWords()
        let own = await Task.detached(priority: .userInitiated) { WordIndex.counts(in: rest) }.value
        var merged = others.counts
        for (word, count) in own { merged[word, default: 0] += count * 4 }
        counts = merged
        sources = others.sources.filter { own[$0.key] == nil }

        let items = items(for: text.substring(with: NSRange(location: start, length: location - start)))
        guard !items.isEmpty else { return nil }
        isShowing = true
        return (CursorPosition(range: NSRange(location: start, length: 0)), items)
    }

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        guard isShowing else { return nil }
        let text = textView.text as NSString
        let location = cursorPosition.range.location
        guard location != NSNotFound, location <= text.length else { return close() }
        let start = WordIndex.wordStart(in: text, before: location)
        guard location - start >= Self.minimumPrefix else { return close() }
        let items = items(for: text.substring(with: NSRange(location: start, length: location - start)))
        return items.isEmpty ? close() : items
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let cursor = cursorPosition ?? textView.cursorPositions.first else { return }
        let text = textView.text as NSString
        let location = min(cursor.range.location, text.length)
        let start = WordIndex.wordStart(in: text, before: location)
        isShowing = false
        completedAt = start + (item.label as NSString).length
        textView.textView.replaceCharacters(in: [NSRange(location: start, length: location - start)], with: item.label)
    }

    func completionWindowDidClose() {
        isShowing = false
    }

    private func close() -> [CodeSuggestionEntry]? {
        isShowing = false
        return nil
    }

    private func items(for prefix: String) -> [CodeSuggestionEntry] {
        WordIndex.ranked(counts, prefix: prefix).map { Item(label: $0, detail: sources[$0]) }
    }

    private func isDigit(_ unit: unichar) -> Bool {
        unit >= 48 && unit <= 57
    }
}
