import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

@Suite("MarkdownText parser")
struct MarkdownTextTests {
    @Test
    @MainActor
    func emptyInputProducesNoBlocks() {
        #expect(MarkdownText.parseBlocks("").isEmpty)
    }

    @Test
    @MainActor
    func parsesParagraphsAndHeadings() {
        let blocks = MarkdownText.parseBlocks("# Title\n\nHello **world**")

        #expect(blocks.map(\.kind) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Hello **world**")
        ])
    }

    @Test
    @MainActor
    func parsesUnorderedAndOrderedLists() {
        let blocks = MarkdownText.parseBlocks("- first\n- second\n\n1. one\n2. two")

        #expect(blocks.map(\.kind) == [
            .unorderedItem("first"),
            .unorderedItem("second"),
            .orderedItem(marker: "1.", text: "one"),
            .orderedItem(marker: "2.", text: "two")
        ])
    }

    @Test
    @MainActor
    func parsesFencedCodeBlocks() {
        let markdown = """
        Before

        ```swift
        let value = 42
        print(value)
        ```

        After
        """

        let blocks = MarkdownText.parseBlocks(markdown)

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .paragraph("Before"))
        #expect(blocks[1].kind == .code(language: "swift", code: "let value = 42\nprint(value)"))
        #expect(blocks[2].kind == .paragraph("After"))
    }

    @Test
    @MainActor
    func parsesBlockQuotesAndHorizontalRules() {
        let blocks = MarkdownText.parseBlocks("> first\n> second\n\n---\n\nDone")

        #expect(blocks.map(\.kind) == [
            .quote("first\nsecond"),
            .rule,
            .paragraph("Done")
        ])
    }

    @Test
    @MainActor
    func parsesGitHubFlavoredPipeTables() {
        let markdown = """
        Before

        | Name | Count | Ratio |
        |:---|---:|:---:|
        | Apples | 12 | 40% |
        | Oranges | 8 | 60% |

        After
        """

        let blocks = MarkdownText.parseBlocks(markdown)

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .paragraph("Before"))
        #expect(blocks[1].kind == .table(MarkdownTable(
            header: ["Name", "Count", "Ratio"],
            alignments: [.leading, .trailing, .center],
            rows: [
                ["Apples", "12", "40%"],
                ["Oranges", "8", "60%"]
            ]
        )))
        #expect(blocks[2].kind == .paragraph("After"))
    }

    @Test
    @MainActor
    func wideTableCellsGrowForLongContent() {
        let table = MarkdownTable(
            header: ["Short", "Description"],
            alignments: [.leading, .leading],
            rows: [[
                "A",
                "This is a long cell that should receive enough width before SwiftUI calculates its wrapped height."
            ]]
        )

        let widths = table.preferredColumnWidths(minWidth: 104, maxWidth: 420)

        #expect(widths.count == 2)
        #expect(widths[0] == 104)
        #expect(widths[1] > 240)
        #expect(widths[1] <= 420)
    }
}
