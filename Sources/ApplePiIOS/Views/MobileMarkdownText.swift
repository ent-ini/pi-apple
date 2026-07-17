import Foundation
import SwiftUI

/// Lightweight Markdown renderer for the mobile chat transcript. It mirrors the
/// Mac renderer enough for common chat output while keeping the iOS target free
/// of extra dependencies: paragraphs, headings, ordered/unordered lists,
/// quotes, code fences, pipe tables, and horizontal rules.
struct MobileMarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if usesSingleSelectableText {
            inlineMarkdownText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.cachedBlocks(for: text)) { block in
                    blockView(block)
                }
            }
            .textSelection(.enabled)
        }
    }

    private var usesSingleSelectableText: Bool {
        Self.cachedBlocks(for: text).allSatisfy { block in
            if case .paragraph = block.kind { return true }
            return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: MobileMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph(let text):
            inlineMarkdownText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inlineMarkdownText(text)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedItem(let text):
            listRow(marker: "•", text: text)
        case .orderedItem(let marker, let text):
            listRow(marker: marker, text: text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                inlineMarkdownText(text)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code.isEmpty ? " " : code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        case .table(let table):
            tableView(table)
        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            inlineMarkdownText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tableView(_ table: MobileMarkdownTable) -> some View {
        MobileMarkdownTablePreview(table: table)
    }

    private func inlineMarkdownText(_ text: String) -> Text {
        if let attributed = MobileMarkdownInlineCache.shared.attributedString(for: text) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }

    private static func cachedBlocks(for markdown: String) -> [MobileMarkdownBlock] {
        MobileMarkdownBlockCache.shared.blocks(for: markdown) {
            parseBlocksUncached(markdown)
        }
    }

    private static func parseBlocksUncached(_ markdown: String) -> [MobileMarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [MobileMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        var lineIndex = 0

        func append(_ kind: MobileMarkdownBlock.Kind) {
            blocks.append(MobileMarkdownBlock(id: index, kind: kind))
            index += 1
        }

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !text.isEmpty {
                append(.paragraph(text))
            }
        }

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }

            if let fence = fenceInfo(from: trimmed) {
                flushParagraph()
                lineIndex += 1
                var codeLines: [String] = []
                while lineIndex < lines.count {
                    let codeLine = lines[lineIndex]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    }
                    codeLines.append(codeLine)
                    lineIndex += 1
                }
                if lineIndex < lines.count {
                    lineIndex += 1
                }
                append(.code(language: fence.language, code: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = headingInfo(from: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level, text: heading.text))
                lineIndex += 1
                continue
            }

            if let table = tableInfo(in: lines, startingAt: lineIndex) {
                flushParagraph()
                append(.table(table.table))
                lineIndex += table.consumedLineCount
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                append(.rule)
                lineIndex += 1
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                append(.unorderedItem(item))
                lineIndex += 1
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                append(.orderedItem(marker: item.marker, text: item.text))
                lineIndex += 1
                continue
            }

            if let quote = quoteText(from: trimmed) {
                flushParagraph()
                var quoteLines = [quote]
                lineIndex += 1
                while lineIndex < lines.count, let continuation = quoteText(from: lines[lineIndex].trimmingCharacters(in: .whitespaces)) {
                    quoteLines.append(continuation)
                    lineIndex += 1
                }
                append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            lineIndex += 1
        }

        flushParagraph()
        return blocks
    }

    private static func fenceInfo(from trimmedLine: String) -> MobileMarkdownFenceInfo? {
        guard trimmedLine.hasPrefix("```") else { return nil }
        let language = String(trimmedLine.dropFirst(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileMarkdownFenceInfo(language: language.nilIfBlank)
    }

    private static func headingInfo(from trimmedLine: String) -> (level: Int, text: String)? {
        var level = 0
        for char in trimmedLine {
            if char == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let afterHashes = trimmedLine.dropFirst(level)
        guard afterHashes.first == " " else { return nil }
        let text = String(afterHashes.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func unorderedItem(from trimmedLine: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if trimmedLine.hasPrefix(marker) {
                let item = String(trimmedLine.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                return item.isEmpty ? nil : item
            }
        }
        return nil
    }

    private static func orderedItem(from trimmedLine: String) -> (marker: String, text: String)? {
        var digitCount = 0
        for char in trimmedLine {
            if char.isNumber { digitCount += 1 } else { break }
        }
        guard digitCount > 0 else { return nil }
        let afterDigits = trimmedLine.dropFirst(digitCount)
        guard afterDigits.hasPrefix(". ") else { return nil }
        let marker = String(trimmedLine.prefix(digitCount)) + "."
        let text = String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (marker, text)
    }

    private static func quoteText(from trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix(">") else { return nil }
        return String(trimmedLine.dropFirst())
            .trimmingCharacters(in: .whitespaces)
    }

    private static func tableInfo(in lines: [String], startingAt lineIndex: Int) -> (table: MobileMarkdownTable, consumedLineCount: Int)? {
        guard lineIndex + 1 < lines.count,
              let header = tableRowCells(from: lines[lineIndex]),
              header.count >= 2,
              let alignments = tableSeparatorAlignments(from: lines[lineIndex + 1]),
              alignments.count == header.count else {
            return nil
        }

        var rows: [[String]] = []
        var cursor = lineIndex + 2
        while cursor < lines.count,
              let row = tableRowCells(from: lines[cursor]),
              row.count > 0 {
            rows.append(normalizedTableRow(row, columnCount: header.count))
            cursor += 1
        }

        return (
            table: MobileMarkdownTable(
                header: normalizedTableRow(header, columnCount: header.count),
                alignments: alignments,
                rows: rows
            ),
            consumedLineCount: cursor - lineIndex
        )
    }

    private static func tableRowCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var isEscaped = false

        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableSeparatorAlignments(from line: String) -> [MobileMarkdownTable.Alignment]? {
        guard let cells = tableRowCells(from: line) else { return nil }
        let alignments = cells.map { cell -> MobileMarkdownTable.Alignment? in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return nil }
            let hasLeadingColon = trimmed.hasPrefix(":")
            let hasTrailingColon = trimmed.hasSuffix(":")
            let core = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .replacingOccurrences(of: " ", with: "")
            guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
            if hasLeadingColon && hasTrailingColon { return .center }
            if hasTrailingColon { return .trailing }
            return .leading
        }
        guard alignments.allSatisfy({ $0 != nil }) else { return nil }
        return alignments.compactMap { $0 }
    }

    private static func normalizedTableRow(_ row: [String], columnCount: Int) -> [String] {
        if row.count == columnCount { return row }
        if row.count > columnCount { return Array(row.prefix(columnCount)) }
        return row + Array(repeating: "", count: columnCount - row.count)
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        guard trimmedLine.count >= 3 else { return false }
        let withoutSpaces = trimmedLine.replacingOccurrences(of: " ", with: "")
        guard withoutSpaces.count >= 3 else { return false }
        return withoutSpaces.allSatisfy { $0 == "-" }
            || withoutSpaces.allSatisfy { $0 == "*" }
            || withoutSpaces.allSatisfy { $0 == "_" }
    }
}

private struct MobileMarkdownTablePreview: View {
    let table: MobileMarkdownTable
    @State private var isExpanded = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            MobileMarkdownTableGrid(table: table, minColumnWidth: 104, maxColumnWidth: 360)
                .fixedSize(horizontal: true, vertical: true)
        }
        #if os(iOS)
        .overlay(alignment: .topTrailing) {
            Button {
                isExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open table in full screen")
            .padding(6)
        }
        #endif
        .textSelection(.disabled)
        #if os(iOS)
        .fullScreenCover(isPresented: $isExpanded) {
            MobileMarkdownTableExpandedView(table: table)
        }
        #endif
    }
}

#if os(iOS)
private struct MobileMarkdownTableExpandedView: View {
    let table: MobileMarkdownTable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                MobileMarkdownTableGrid(table: table, minColumnWidth: 128, maxColumnWidth: 720)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(16)
            }
            .navigationTitle("Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#endif

private struct MobileMarkdownTableGrid: View {
    let table: MobileMarkdownTable
    let minColumnWidth: CGFloat
    let maxColumnWidth: CGFloat

    private var columnWidths: [CGFloat] {
        table.preferredColumnWidths(minWidth: minColumnWidth, maxWidth: maxColumnWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableRow(table.header, isHeader: true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                tableRow(row, isHeader: false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                tableCell(
                    cells[safe: column] ?? "",
                    alignment: table.alignment(for: column),
                    isHeader: isHeader,
                    width: columnWidths[safe: column] ?? minColumnWidth
                )
            }
        }
        .frame(minHeight: isHeader ? 38 : 40, alignment: .topLeading)
        .background(isHeader ? Color.primary.opacity(0.055) : Color.clear)
        .overlay(Rectangle().fill(Color.secondary.opacity(0.14)).frame(height: 1), alignment: .bottom)
        .overlay(tableVerticalDividers)
    }

    private var tableVerticalDividers: some View {
        GeometryReader { geometry in
            Path { path in
                var x: CGFloat = 0
                for width in columnWidths.dropLast() {
                    x += width
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
            }
            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func tableCell(_ text: String, alignment: MobileMarkdownTable.Alignment, isHeader: Bool, width: CGFloat) -> some View {
        mobileMarkdownInlineText(text.isEmpty ? " " : text)
            .font(isHeader ? .body.weight(.semibold) : .body)
            .lineSpacing(2)
            .lineLimit(nil)
            .multilineTextAlignment(alignment.textAlignment)
            .frame(width: max(1, width - 24), alignment: alignment.frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: width, alignment: alignment.frameAlignment)
    }
}

private func mobileMarkdownInlineText(_ text: String) -> Text {
    if let attributed = MobileMarkdownInlineCache.shared.attributedString(for: text) {
        return Text(attributed)
    }
    return Text(text)
}

private final class MobileMarkdownInlineCache: @unchecked Sendable {
    static let shared = MobileMarkdownInlineCache()

    private final class Box {
        let attributed: AttributedString

        init(_ attributed: AttributedString) {
            self.attributed = attributed
        }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 2_000
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func attributedString(for markdown: String) -> AttributedString? {
        let key = markdown as NSString
        if let box = cache.object(forKey: key) {
            return box.attributed
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return nil
        }
        cache.setObject(Box(attributed), forKey: key, cost: max(1, markdown.utf8.count))
        return attributed
    }
}

private final class MobileMarkdownBlockCache: @unchecked Sendable {
    static let shared = MobileMarkdownBlockCache()

    private final class Box {
        let blocks: [MobileMarkdownBlock]

        init(_ blocks: [MobileMarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 500
    }

    func blocks(for markdown: String, build: () -> [MobileMarkdownBlock]) -> [MobileMarkdownBlock] {
        let key = markdown as NSString
        if let box = cache.object(forKey: key) {
            return box.blocks
        }
        let blocks = build()
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}

private struct MobileMarkdownFenceInfo: Sendable {
    let language: String?
}

private struct MobileMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedItem(String)
        case orderedItem(marker: String, text: String)
        case quote(String)
        case code(language: String?, code: String)
        case table(MobileMarkdownTable)
        case rule
    }

    let id: Int
    let kind: Kind
}

private struct MobileMarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing

        var frameAlignment: SwiftUI.Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    var columnCount: Int {
        max(header.count, alignments.count)
    }

    func alignment(for column: Int) -> Alignment {
        alignments[safe: column] ?? .leading
    }

    func preferredColumnWidths(minWidth: CGFloat, maxWidth: CGFloat) -> [CGFloat] {
        (0..<columnCount).map { column in
            preferredColumnWidth(for: column, minWidth: minWidth, maxWidth: maxWidth)
        }
    }

    private func preferredColumnWidth(for column: Int, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let values = [header[safe: column] ?? ""] + rows.map { $0[safe: column] ?? "" }
        let longestLineLength = values
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false) }
            .map(\.count)
            .max() ?? 0
        let longestTokenLength = values
            .map(Self.longestTokenLength(in:))
            .max() ?? 0
        let lineCharacterCap = max(72, Int(maxWidth / 7.2))
        let tokenCharacterCap = max(44, Int(maxWidth / 8.2))
        let lineDrivenWidth = CGFloat(min(longestLineLength, lineCharacterCap)) * 7.2
        let tokenDrivenWidth = CGFloat(min(longestTokenLength, tokenCharacterCap)) * 8.2
        let preferredWidth = max(minWidth, lineDrivenWidth, tokenDrivenWidth)
        return min(maxWidth, ceil(preferredWidth))
    }

    private static func longestTokenLength(in text: String) -> Int {
        text.split { character in
            character.isWhitespace || "/\\-–—_,.;:!?()[]{}<>".contains(character)
        }
        .map(\.count)
        .max() ?? 0
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
