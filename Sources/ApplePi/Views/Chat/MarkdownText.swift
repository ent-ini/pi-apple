import Foundation
import SwiftUI
import ApplePiCore
import ApplePiRemote

/// Lightweight Markdown renderer for chat messages. It intentionally avoids
/// adding a heavy dependency while covering the shapes Pi responses commonly
/// use: paragraphs with inline emphasis/code/links, headings, lists, block
/// quotes, GitHub-flavored pipe tables, horizontal rules, and fenced code blocks.
struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if usesSingleSelectableText {
            // SwiftUI selection is scoped per Text view. Plain multi-paragraph
            // chat messages used to be split into multiple Text views, so a
            // drag could only select one block at a time. Render simple
            // paragraph-only messages as one Text so selection can span the
            // whole bubble.
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
    private func blockView(_ block: MarkdownBlock) -> some View {
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

    private func tableView(_ table: MarkdownTable) -> some View {
        MarkdownTablePreview(table: table)
    }

    private func inlineMarkdownText(_ text: String) -> Text {
        if let attributed = MarkdownInlineCache.shared.attributedString(for: text) {
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

    static func parseBlocks(_ markdown: String) -> [MarkdownBlock] {
        cachedBlocks(for: markdown)
    }

    private static func cachedBlocks(for markdown: String) -> [MarkdownBlock] {
        MarkdownBlockCache.shared.blocks(for: markdown) {
            parseBlocksUncached(markdown)
        }
    }

    private static func parseBlocksUncached(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        var lineIndex = 0

        func append(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: index, kind: kind))
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

    private static func fenceInfo(from trimmedLine: String) -> MarkdownFenceInfo? {
        guard trimmedLine.hasPrefix("```") else { return nil }
        let language = String(trimmedLine.dropFirst(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownFenceInfo(language: language.nilIfBlank)
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

    private static func tableInfo(in lines: [String], startingAt lineIndex: Int) -> (table: MarkdownTable, consumedLineCount: Int)? {
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
            table: MarkdownTable(
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
        if isEscaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if cells.first == "" {
            cells.removeFirst()
        }
        if cells.last == "" {
            cells.removeLast()
        }
        return cells.isEmpty ? nil : cells
    }

    private static func tableSeparatorAlignments(from line: String) -> [MarkdownTable.Alignment]? {
        guard let cells = tableRowCells(from: line) else { return nil }
        let alignments = cells.map { cell -> MarkdownTable.Alignment? in
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

private struct MarkdownTablePreview: View {
    let table: MarkdownTable
    @State private var expandedTable: ExpandedMarkdownTable?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: true) {
                MarkdownTableGrid(table: table, minColumnWidth: 112, maxColumnWidth: 760)
                    .fixedSize(horizontal: true, vertical: true)
            }
            Button {
                expandedTable = ExpandedMarkdownTable(table: table)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .padding(7)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.borderless)
            .help("Open table in a larger view")
            .padding(6)
        }
        // The parent message supports drag-to-select text. Disable that mode
        // for the interactive table control so its button receives clicks.
        .textSelection(.disabled)
        .sheet(item: $expandedTable) { item in
            MarkdownTableExpandedView(table: item.table)
        }
    }
}

private struct ExpandedMarkdownTable: Identifiable {
    let id = UUID()
    let table: MarkdownTable
}

private struct MarkdownTableExpandedView: View {
    let table: MarkdownTable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Table")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                MarkdownTableGrid(table: table, minColumnWidth: 140, maxColumnWidth: 1_200)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(20)
            }
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 480, idealHeight: 640)
    }
}

private struct MarkdownTableGrid: View {
    let table: MarkdownTable
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

    private func tableCell(_ text: String, alignment: MarkdownTable.Alignment, isHeader: Bool, width: CGFloat) -> some View {
        markdownInlineText(text.isEmpty ? " " : text)
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

private func markdownInlineText(_ text: String) -> Text {
    if let attributed = MarkdownInlineCache.shared.attributedString(for: text) {
        return Text(attributed)
    }
    return Text(text)
}

private final class MarkdownInlineCache: @unchecked Sendable {
    static let shared = MarkdownInlineCache()

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

private final class MarkdownBlockCache: @unchecked Sendable {
    static let shared = MarkdownBlockCache()

    private final class Box {
        let blocks: [MarkdownBlock]

        init(_ blocks: [MarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 500
    }

    func blocks(for markdown: String, build: () -> [MarkdownBlock]) -> [MarkdownBlock] {
        let key = markdown as NSString
        if let box = cache.object(forKey: key) {
            return box.blocks
        }
        let blocks = build()
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}

private struct MarkdownFenceInfo: Sendable {
    let language: String?
}

struct MarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedItem(String)
        case orderedItem(marker: String, text: String)
        case quote(String)
        case code(language: String?, code: String)
        case table(MarkdownTable)
        case rule
    }

    let id: Int
    let kind: Kind
}

struct MarkdownTable: Equatable, Sendable {
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
