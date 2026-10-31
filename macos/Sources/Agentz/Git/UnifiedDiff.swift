import Foundation

enum PartialPatchDirection: Sendable {
    case forward
    case reverse
}

enum UnifiedDiffLineKind: Equatable, Sendable {
    case metadata
    case hunkHeader
    case context
    case addition
    case deletion
    case noNewline

    var isSelectableChange: Bool {
        self == .addition || self == .deletion
    }
}

struct UnifiedDiffLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let kind: UnifiedDiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?

    /// The line's content without the unified-diff marker column.
    var displayText: String {
        switch kind {
        case .context, .addition, .deletion:
            String(text.dropFirst())
        default:
            text
        }
    }
}

struct UnifiedDiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: UnifiedDiffLine
    let lines: [UnifiedDiffLine]
    let selectableLineIDs: Set<Int>
}

/// How a commit or patch touched one file, as reported by the diff header.
enum UnifiedDiffFileChange: Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied

    /// The single-letter Git status, matching the letters the working-tree
    /// change list uses so both lists share `Color.statusColor`.
    var symbol: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        }
    }

    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}

struct UnifiedDiffFile: Identifiable, Equatable, Sendable {
    let id: Int
    let path: String
    /// The pre-rename or pre-copy path, when the header reports one.
    let originalPath: String?
    let change: UnifiedDiffFileChange
    let additions: Int
    let deletions: Int
    let lines: [UnifiedDiffLine]
}

struct UnifiedDiff: Sendable {
    let lines: [UnifiedDiffLine]
    let preambleLines: [UnifiedDiffLine]
    let files: [UnifiedDiffFile]
    let displayHunks: [UnifiedDiffHunk]
    let selectableLineIDs: Set<Int>
    private let hunks: [Hunk]

    init(_ text: String) {
        var rawLines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n"), rawLines.last == "" {
            rawLines.removeLast()
        }
        var parsedLines: [UnifiedDiffLine] = []
        var parsedHunks: [Hunk] = []
        var currentHunkStart: Int?
        var currentRange: HunkRange?
        var oldLineCursor: Int?
        var newLineCursor: Int?

        for (index, text) in rawLines.enumerated() {
            if text.hasPrefix("diff --git "),
               let openHunkStart = currentHunkStart,
               let openRange = currentRange {
                parsedHunks.append(
                    Hunk(
                        headerIndex: openHunkStart,
                        bodyRange: (openHunkStart + 1)..<index,
                        range: openRange
                    )
                )
                currentHunkStart = nil
                currentRange = nil
                oldLineCursor = nil
                newLineCursor = nil
            }

            let range = HunkRange(header: text)
            if let range {
                if let currentHunkStart, let currentRange {
                    parsedHunks.append(
                        Hunk(
                            headerIndex: currentHunkStart,
                            bodyRange: (currentHunkStart + 1)..<index,
                            range: currentRange
                        )
                    )
                }
                currentHunkStart = index
                currentRange = range
                oldLineCursor = range.oldStart
                newLineCursor = range.newStart
            }

            let kind = Self.kind(for: text, isInsideHunk: currentHunkStart != nil)
            let lineNumbers = Self.lineNumbers(
                for: kind,
                oldCursor: &oldLineCursor,
                newCursor: &newLineCursor
            )
            parsedLines.append(
                UnifiedDiffLine(
                    id: index,
                    text: text,
                    kind: kind,
                    oldLineNumber: lineNumbers.old,
                    newLineNumber: lineNumbers.new
                )
            )
        }

        if let currentHunkStart, let currentRange {
            parsedHunks.append(
                Hunk(
                    headerIndex: currentHunkStart,
                    bodyRange: (currentHunkStart + 1)..<rawLines.count,
                    range: currentRange
                )
            )
        }

        lines = parsedLines
        selectableLineIDs = Set(
            parsedLines.lazy.filter { $0.kind.isSelectableChange }.map(\.id)
        )
        let fileStarts = parsedLines.indices.filter {
            parsedLines[$0].text.hasPrefix("diff --git ")
        }
        preambleLines = Array(parsedLines[..<(fileStarts.first ?? parsedLines.count)])
        files = fileStarts.enumerated().map { offset, start in
            let end = offset + 1 < fileStarts.count
                ? fileStarts[offset + 1]
                : parsedLines.count
            let fileLines = Array(parsedLines[start..<end])
            return UnifiedDiffFile(
                id: start,
                path: Self.filePath(in: fileLines),
                originalPath: Self.originalPath(in: fileLines),
                change: Self.change(in: fileLines),
                additions: fileLines.lazy.filter { $0.kind == .addition }.count,
                deletions: fileLines.lazy.filter { $0.kind == .deletion }.count,
                lines: fileLines
            )
        }
        hunks = parsedHunks
        displayHunks = parsedHunks.map { hunk in
            UnifiedDiffHunk(
                id: hunk.headerIndex,
                header: parsedLines[hunk.headerIndex],
                lines: Array(parsedLines[hunk.bodyRange]),
                selectableLineIDs: Set(
                    parsedLines[hunk.bodyRange].lazy
                        .filter { $0.kind.isSelectableChange }
                        .map(\.id)
                )
            )
        }
    }

    private static func filePath(in lines: [UnifiedDiffLine]) -> String {
        let destinationPath = lines.first {
            $0.text.hasPrefix("rename to ") || $0.text.hasPrefix("copy to ")
        }
        .map {
            $0.text.hasPrefix("rename to ")
                ? unquoted(String($0.text.dropFirst("rename to ".count)))
                : unquoted(String($0.text.dropFirst("copy to ".count)))
        }
        let newPath = lines.first { $0.text.hasPrefix("+++ ") }
            .map { String($0.text.dropFirst(4)) }
        let oldPath = lines.first { $0.text.hasPrefix("--- ") }
            .map { String($0.text.dropFirst(4)) }
        let patchPath = newPath == "/dev/null" ? oldPath : newPath
        let path = destinationPath ?? patchPath ?? diffHeaderPath(lines.first?.text)

        guard var path else {
            return "Changed file"
        }
        if path.hasPrefix("\"a/") || path.hasPrefix("\"b/") {
            path.removeFirst(3)
            if path.hasSuffix("\"") {
                path.removeLast()
            }
        } else if path.hasPrefix("a/") || path.hasPrefix("b/") {
            path.removeFirst(2)
        }
        return path
    }

    /// Header markers such as `rename from` never appear inside a hunk body,
    /// where every line carries a `+`, `-`, or space marker, so an unanchored
    /// prefix match cannot collide with file content.
    private static func originalPath(in lines: [UnifiedDiffLine]) -> String? {
        let prefixes = ["rename from ", "copy from "]
        for line in lines {
            guard let prefix = prefixes.first(where: { line.text.hasPrefix($0) }) else {
                continue
            }
            return unquoted(String(line.text.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func change(in lines: [UnifiedDiffLine]) -> UnifiedDiffFileChange {
        for line in lines {
            if line.text.hasPrefix("new file mode ") { return .added }
            if line.text.hasPrefix("deleted file mode ") { return .deleted }
            if line.text.hasPrefix("rename from ") { return .renamed }
            if line.text.hasPrefix("copy from ") { return .copied }
        }
        return .modified
    }

    private static func unquoted(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 else {
            return path
        }
        return String(path.dropFirst().dropLast())
    }

    private static func diffHeaderPath(_ header: String?) -> String? {
        guard let header, header.hasPrefix("diff --git ") else { return nil }
        if let range = header.range(of: " \"b/", options: .backwards) {
            var path = String(header[range.upperBound...])
            if path.hasSuffix("\"") {
                path.removeLast()
            }
            return path
        }
        if let range = header.range(of: " b/", options: .backwards) {
            return String(header[range.upperBound...])
        }
        return nil
    }

    func partialPatch(
        selecting selectedLineIDs: Set<Int>,
        direction: PartialPatchDirection,
        treatNewFileAsExisting: Bool = false
    ) -> String? {
        let selected = selectedLineIDs.intersection(selectableLineIDs)
        guard !selected.isEmpty, let firstHunk = hunks.first else { return nil }

        var output = lines[..<firstHunk.headerIndex].map(\.text)
        var cumulativeSelectedDelta = 0
        var emittedHunk = false

        for hunk in hunks {
            let selectedInHunk = selected.filter { hunk.bodyRange.contains($0) }
            guard !selectedInHunk.isEmpty else { continue }

            let transformed = transform(
                hunk: hunk,
                selected: selectedInHunk,
                direction: direction
            )
            let oldStart: Int
            let newStart: Int

            switch direction {
            case .forward:
                oldStart = hunk.range.oldStart
                newStart = Self.transformedStart(
                    exactStart: hunk.range.oldStart,
                    exactCount: transformed.oldCount,
                    transformedCount: transformed.newCount,
                    cumulativeDelta: cumulativeSelectedDelta
                )

            case .reverse:
                newStart = hunk.range.newStart
                oldStart = Self.transformedStart(
                    exactStart: hunk.range.newStart,
                    exactCount: transformed.newCount,
                    transformedCount: transformed.oldCount,
                    cumulativeDelta: -cumulativeSelectedDelta
                )
            }

            output.append(
                Self.hunkHeader(
                    oldStart: oldStart,
                    oldCount: transformed.oldCount,
                    newStart: newStart,
                    newCount: transformed.newCount,
                    suffix: hunk.range.suffix
                )
            )
            output.append(contentsOf: transformed.lines)
            cumulativeSelectedDelta += transformed.selectedDelta
            emittedHunk = true
        }

        guard emittedHunk else { return nil }
        if treatNewFileAsExisting {
            output = Self.normalizeNewFileHeader(output)
        }
        return output.joined(separator: "\n") + "\n"
    }

    private func transform(
        hunk: Hunk,
        selected: Set<Int>,
        direction: PartialPatchDirection
    ) -> TransformedHunk {
        var transformedLines: [String] = []
        var oldCount = 0
        var newCount = 0
        var additions = 0
        var deletions = 0
        var emittedPreviousSourceLine = false

        for id in hunk.bodyRange {
            let line = lines[id]
            let transformed: String?

            switch line.kind {
            case .addition:
                if selected.contains(id) {
                    transformed = line.text
                    additions += 1
                } else {
                    transformed = direction == .forward
                        ? nil
                        : " " + line.text.dropFirst()
                }

            case .deletion:
                if selected.contains(id) {
                    transformed = line.text
                    deletions += 1
                } else {
                    transformed = direction == .forward
                        ? " " + line.text.dropFirst()
                        : nil
                }

            case .noNewline:
                transformed = emittedPreviousSourceLine ? line.text : nil

            default:
                transformed = line.text
            }

            guard let transformed else {
                emittedPreviousSourceLine = false
                continue
            }

            transformedLines.append(transformed)
            emittedPreviousSourceLine = line.kind != .noNewline
            if transformed.hasPrefix("+") {
                newCount += 1
            } else if transformed.hasPrefix("-") {
                oldCount += 1
            } else if line.kind != .noNewline {
                oldCount += 1
                newCount += 1
            }
        }

        return TransformedHunk(
            lines: transformedLines,
            oldCount: oldCount,
            newCount: newCount,
            selectedDelta: additions - deletions
        )
    }

    private static func kind(for text: String, isInsideHunk: Bool) -> UnifiedDiffLineKind {
        if HunkRange(header: text) != nil { return .hunkHeader }
        guard isInsideHunk else { return .metadata }
        if text.hasPrefix("+") { return .addition }
        if text.hasPrefix("-") { return .deletion }
        if text.hasPrefix("\\") { return .noNewline }
        return .context
    }

    private static func lineNumbers(
        for kind: UnifiedDiffLineKind,
        oldCursor: inout Int?,
        newCursor: inout Int?
    ) -> (old: Int?, new: Int?) {
        switch kind {
        case .context:
            let numbers = (oldCursor, newCursor)
            oldCursor = oldCursor.map { $0 + 1 }
            newCursor = newCursor.map { $0 + 1 }
            return numbers

        case .deletion:
            let number = oldCursor
            oldCursor = oldCursor.map { $0 + 1 }
            return (number, nil)

        case .addition:
            let number = newCursor
            newCursor = newCursor.map { $0 + 1 }
            return (nil, number)

        default:
            return (nil, nil)
        }
    }

    private static func transformedStart(
        exactStart: Int,
        exactCount: Int,
        transformedCount: Int,
        cumulativeDelta: Int
    ) -> Int {
        let adjusted = exactStart + cumulativeDelta
        if exactCount == 0, transformedCount > 0 {
            return adjusted + 1
        }
        if exactCount > 0, transformedCount == 0 {
            return adjusted - 1
        }
        return adjusted
    }

    private static func hunkHeader(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        suffix: String
    ) -> String {
        "@@ -\(rangeText(start: oldStart, count: oldCount)) +\(rangeText(start: newStart, count: newCount)) @@\(suffix)"
    }

    private static func rangeText(start: Int, count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }

    private static func normalizeNewFileHeader(_ lines: [String]) -> [String] {
        guard lines.contains(where: { $0.hasPrefix("new file mode ") }),
              let newPathHeader = lines.first(where: { $0.hasPrefix("+++ ") }) else {
            return lines
        }

        let oldPathHeader: String
        if newPathHeader.hasPrefix("+++ b/") {
            oldPathHeader = "--- a/" + newPathHeader.dropFirst("+++ b/".count)
        } else if newPathHeader.hasPrefix("+++ \"b/") {
            oldPathHeader = "--- \"a/" + newPathHeader.dropFirst("+++ \"b/".count)
        } else {
            return lines
        }

        return lines.compactMap { line in
            if line.hasPrefix("new file mode ") || line.hasPrefix("index 0000000..") {
                return nil
            }
            if line == "--- /dev/null" {
                return oldPathHeader
            }
            return line
        }
    }
}

private struct Hunk: Sendable {
    let headerIndex: Int
    let bodyRange: Range<Int>
    let range: HunkRange
}

private struct HunkRange: Sendable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let suffix: String

    init?(header: String) {
        guard header.hasPrefix("@@ "),
              let closingRange = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: 3)..<header.endIndex) else {
            return nil
        }

        let body = header[header.index(header.startIndex, offsetBy: 3)..<closingRange.lowerBound]
        let fields = body.split(separator: " ")
        guard fields.count >= 2,
              let oldRange = Self.parseRange(fields[0], prefix: "-"),
              let newRange = Self.parseRange(fields[1], prefix: "+") else {
            return nil
        }

        oldStart = oldRange.start
        oldCount = oldRange.count
        newStart = newRange.start
        newCount = newRange.count
        suffix = String(header[closingRange.upperBound...])
    }

    private static func parseRange(
        _ field: Substring,
        prefix: Character
    ) -> (start: Int, count: Int)? {
        guard field.first == prefix else { return nil }
        let values = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let startText = values.first, let start = Int(startText) else { return nil }
        let count = values.count == 1 ? 1 : Int(values[1])
        guard let count else { return nil }
        return (start, count)
    }
}

private struct TransformedHunk: Sendable {
    let lines: [String]
    let oldCount: Int
    let newCount: Int
    let selectedDelta: Int
}
