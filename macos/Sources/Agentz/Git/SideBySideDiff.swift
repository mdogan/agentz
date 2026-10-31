import Foundation

/// Which version of a file a side-by-side column represents.
enum SideBySideDiffSide: Sendable {
    case old
    case new
}

/// One row of a side-by-side comparison. A side is `nil` when that version of
/// the file has no counterpart for the row, which renders as a filler cell.
struct SideBySideDiffRow: Identifiable, Equatable, Sendable {
    let id: Int
    let old: UnifiedDiffLine?
    let new: UnifiedDiffLine?

    func line(_ side: SideBySideDiffSide) -> UnifiedDiffLine? {
        side == .old ? old : new
    }
}

struct SideBySideDiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: UnifiedDiffLine
    let rows: [SideBySideDiffRow]
    let selectableLineIDs: Set<Int>
}

/// One visual line in a side-by-side column's continuous text surface.
/// Keeping filler rows here preserves alignment while allowing one native text
/// selection to extend across every displayed line and hunk.
struct SideBySideDiffColumnLine: Equatable, Sendable {
    let text: String
    let kind: UnifiedDiffLineKind
    let addsHunkSpacing: Bool
}

/// A unified diff re-laid out as two aligned columns: the old version of a file
/// on the left and the new version on the right.
///
/// Deletions and additions that sit next to each other are paired row by row so
/// a rewritten line appears opposite its replacement; the longer run pads the
/// shorter side with empty cells.
struct SideBySideDiff: Equatable, Sendable {
    let hunks: [SideBySideDiffHunk]

    /// Width, in monospaced character cells, of the widest line in each column.
    /// Used to size the columns so long lines scroll instead of wrapping.
    let oldColumnCharacters: Int
    let newColumnCharacters: Int

    var isEmpty: Bool {
        hunks.isEmpty
    }

    var rowCount: Int {
        hunks.reduce(0) { $0 + $1.rows.count }
    }

    func columnLines(on side: SideBySideDiffSide) -> [SideBySideDiffColumnLine] {
        hunks.flatMap { hunk in
            var lines = [
                SideBySideDiffColumnLine(
                    text: hunk.header.text,
                    kind: hunk.header.kind,
                    addsHunkSpacing: hunk.rows.isEmpty
                )
            ]
            lines.append(contentsOf: hunk.rows.enumerated().map { index, row in
                let line = row.line(side)
                return SideBySideDiffColumnLine(
                    text: line?.displayText ?? "",
                    kind: line?.kind ?? .context,
                    addsHunkSpacing: index == hunk.rows.indices.last
                )
            })
            return lines
        }
    }

    init(_ document: UnifiedDiff) {
        let parsedHunks = document.displayHunks.map { hunk in
            SideBySideDiffHunk(
                id: hunk.id,
                header: hunk.header,
                rows: Self.rows(for: hunk.lines),
                selectableLineIDs: hunk.selectableLineIDs
            )
        }
        hunks = parsedHunks
        oldColumnCharacters = Self.widestLine(in: parsedHunks, on: .old)
        newColumnCharacters = Self.widestLine(in: parsedHunks, on: .new)
    }

    private static func rows(for lines: [UnifiedDiffLine]) -> [SideBySideDiffRow] {
        var rows: [SideBySideDiffRow] = []
        var oldSide: [UnifiedDiffLine] = []
        var newSide: [UnifiedDiffLine] = []
        var lastChangeKind = UnifiedDiffLineKind.context

        func flushPairedLines() {
            for index in 0..<max(oldSide.count, newSide.count) {
                let old = index < oldSide.count ? oldSide[index] : nil
                let new = index < newSide.count ? newSide[index] : nil
                guard let id = old?.id ?? new?.id else { continue }
                rows.append(SideBySideDiffRow(id: id, old: old, new: new))
            }
            oldSide.removeAll()
            newSide.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .deletion:
                // A deletion after additions begins a new replacement block.
                if !newSide.isEmpty {
                    flushPairedLines()
                }
                oldSide.append(line)
                lastChangeKind = .deletion

            case .addition:
                newSide.append(line)
                lastChangeKind = .addition

            case .noNewline:
                // The marker belongs to whichever version owns the line above it.
                switch lastChangeKind {
                case .deletion:
                    oldSide.append(line)
                case .addition:
                    newSide.append(line)
                default:
                    oldSide.append(line)
                    newSide.append(line)
                }

            default:
                flushPairedLines()
                rows.append(SideBySideDiffRow(id: line.id, old: line, new: line))
                lastChangeKind = .context
            }
        }

        flushPairedLines()
        return rows
    }

    private static func widestLine(
        in hunks: [SideBySideDiffHunk],
        on side: SideBySideDiffSide
    ) -> Int {
        hunks.reduce(0) { widest, hunk in
            hunk.rows.reduce(widest) { widest, row in
                guard let line = row.line(side) else { return widest }
                return max(widest, characterWidth(of: line.displayText))
            }
        }
    }

    /// Approximates how many monospaced cells a line occupies. Tabs advance to
    /// the next four-column stop and non-ASCII scalars are assumed double width,
    /// so the estimate never falls short of what is drawn.
    private static func characterWidth(of text: String) -> Int {
        text.reduce(0) { width, character in
            if character == "\t" {
                return width + 4 - width % 4
            }
            return width + (character.isASCII ? 1 : 2)
        }
    }
}
