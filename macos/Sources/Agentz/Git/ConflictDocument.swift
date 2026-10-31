import Foundation

/// One well-formed conflict-marker block in a UTF-8 working-tree file.
///
/// The ranges use zero-based file line indices. The block ID is its opening
/// marker line, which is stable while resolving blocks later in the file.
struct ConflictBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let endLine: Int
    let markerSize: Int
    let oursLabel: String
    let theirsLabel: String
    let baseLabel: String?
    let oursLines: [String]
    let theirsLines: [String]
    let baseLines: [String]?

    var lineRange: ClosedRange<Int> {
        id...endLine
    }
}

/// Parses Git's merge, diff3, and zdiff3 working-tree conflict markers and
/// produces replacements for one block at a time without touching the index.
struct ConflictDocument: Equatable, Sendable {
    let text: String
    let conflicts: [ConflictBlock]
    let hasUnparsedMarkers: Bool

    private let lines: [String]
    private let hasTrailingNewline: Bool

    init(_ text: String) {
        self.text = text
        hasTrailingNewline = text.hasSuffix("\n")

        var parsedLines = text.components(separatedBy: "\n")
        if hasTrailingNewline, parsedLines.last == "" {
            parsedLines.removeLast()
        }
        lines = parsedLines

        let parsed = Self.parseBlocks(in: parsedLines)
        conflicts = parsed.blocks
        hasUnparsedMarkers = parsedLines.indices.contains { index in
            !parsed.consumedLines.contains(index)
                && Self.marker(in: parsedLines[index]) != nil
        }
    }

    func resolving(
        blockID: ConflictBlock.ID,
        using side: ConflictResolutionSide
    ) -> String? {
        guard let block = conflicts.first(where: { $0.id == blockID }) else {
            return nil
        }

        var resolvedLines = lines
        let replacement = switch side {
        case .ours: block.oursLines
        case .theirs: block.theirsLines
        }
        resolvedLines.replaceSubrange(block.lineRange, with: replacement)

        var resolved = resolvedLines.joined(separator: "\n")
        if hasTrailingNewline {
            resolved += "\n"
        }
        return resolved
    }

    private struct Marker {
        let character: Character
        let size: Int
        let label: String
    }

    private static func parseBlocks(
        in lines: [String]
    ) -> (blocks: [ConflictBlock], consumedLines: Set<Int>) {
        var blocks: [ConflictBlock] = []
        var consumedLines: Set<Int> = []
        var cursor = 0

        while cursor < lines.count {
            guard let opening = marker(in: lines[cursor]),
                  opening.character == "<" else {
                cursor += 1
                continue
            }

            let start = cursor
            var baseIndex: Int?
            var baseMarker: Marker?
            var separatorIndex: Int?
            var index = start + 1

            while index < lines.count {
                if let candidate = marker(in: lines[index]),
                   candidate.size == opening.size {
                    if candidate.character == "|", baseIndex == nil {
                        baseIndex = index
                        baseMarker = candidate
                    } else if candidate.character == "=", candidate.label.isEmpty {
                        separatorIndex = index
                        break
                    } else if candidate.character == "<" {
                        // A second opening marker means this candidate block is
                        // malformed. Resume at that marker so it can be parsed.
                        break
                    }
                }
                index += 1
            }

            guard let separatorIndex else {
                cursor = max(start + 1, index)
                continue
            }

            var endIndex: Int?
            var closingMarker: Marker?
            index = separatorIndex + 1
            while index < lines.count {
                if let candidate = marker(in: lines[index]),
                   candidate.character == ">",
                   candidate.size == opening.size {
                    endIndex = index
                    closingMarker = candidate
                    break
                }
                index += 1
            }

            guard let endIndex, let closingMarker else {
                cursor = separatorIndex + 1
                continue
            }

            let oursEnd = baseIndex ?? separatorIndex
            let oursLines = Array(lines[(start + 1)..<oursEnd])
            let baseLines = baseIndex.map {
                Array(lines[($0 + 1)..<separatorIndex])
            }
            let theirsLines = Array(lines[(separatorIndex + 1)..<endIndex])
            let block = ConflictBlock(
                id: start,
                endLine: endIndex,
                markerSize: opening.size,
                oursLabel: opening.label,
                theirsLabel: closingMarker.label,
                baseLabel: baseMarker?.label,
                oursLines: oursLines,
                theirsLines: theirsLines,
                baseLines: baseLines
            )
            blocks.append(block)
            consumedLines.formUnion(block.lineRange)
            cursor = endIndex + 1
        }

        return (blocks, consumedLines)
    }

    /// A marker is seven or more identical marker characters followed by an
    /// optional whitespace-separated label. Git can configure the run length
    /// per path with the `conflict-marker-size` attribute.
    private static func marker(in line: String) -> Marker? {
        guard let first = line.first,
              first == "<" || first == "|" || first == "=" || first == ">" else {
            return nil
        }

        let size = line.prefix { $0 == first }.count
        guard size >= 7 else { return nil }
        let remainder = line.dropFirst(size)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else {
            return nil
        }
        return Marker(
            character: first,
            size: size,
            label: remainder.trimmingCharacters(in: .whitespaces)
        )
    }
}
