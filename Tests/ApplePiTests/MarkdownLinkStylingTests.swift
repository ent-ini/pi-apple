import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import ApplePiCore

@Suite("MarkdownLinkStyling")
struct MarkdownLinkStylingTests {

    @Test
    func markdownLinkGetsLinkAttributeAndHighlight() throws {
        let attributed = try #require(
            MarkdownLinkStyling.parseInline("see [docs](https://example.com) now")
        )
        let links = attributed.runs.filter { $0.link != nil }
        #expect(links.count == 1)
        let run = try #require(links.first)
        #expect(run.link?.absoluteString == "https://example.com")
        #expect(String(attributed[run.range].characters) == "docs")
        // NB: the explicit NSColor context matters — with both AppKit and
        // SwiftUI attribute scopes visible, an untyped `.foregroundColor`
        // read resolves to the SwiftUI scope key and reports nil.
        let linkColor: NSColor? = attributed[run.range].foregroundColor
        #expect(linkColor != nil)
        #expect(attributed[run.range].underlineStyle == .single)
    }

    @Test
    func bareURLBecomesClickableLink() throws {
        let attributed = try #require(
            MarkdownLinkStyling.parseInline("open https://example.com/path?q=1 please")
        )
        let links = attributed.runs.filter { $0.link != nil }
        #expect(links.count == 1)
        let run = try #require(links.first)
        #expect(run.link?.absoluteString == "https://example.com/path?q=1")
        #expect(String(attributed[run.range].characters) == "https://example.com/path?q=1")
        #expect(attributed[run.range].underlineStyle == .single)
    }

    @Test
    func urlInsideInlineCodeStaysPlain() throws {
        let attributed = try #require(
            MarkdownLinkStyling.parseInline("run `curl https://example.com` now")
        )
        #expect(attributed.runs.allSatisfy { $0.link == nil })
    }

    @Test
    func explicitMarkdownLinkDestinationIsNotOverwritten() throws {
        let attributed = try #require(
            MarkdownLinkStyling.parseInline("[https://example.com](https://example.org)")
        )
        let links = attributed.runs.filter { $0.link != nil }
        #expect(links.count == 1)
        #expect(links.first?.link?.absoluteString == "https://example.org")
    }

    @Test
    func plainTextAndFilePathsHaveNoLinks() throws {
        let attributed = try #require(
            MarkdownLinkStyling.parseInline("no links here, just /home/agent/workspace and wiki-memory/")
        )
        #expect(attributed.runs.allSatisfy { $0.link == nil })
    }

    @Test
    func mixedContentLinksEverythingClickable() throws {
        let attributed = try #require(
            MarkdownLinkStyling.parseInline(
                "check [repo](https://github.com/ent-ini/pi-apple), then https://github.com/dodo-reach/apple-pi"
            )
        )
        let urls = attributed.runs.compactMap { $0.link?.absoluteString }
        #expect(urls.count == 2)
        #expect(urls.contains("https://github.com/ent-ini/pi-apple"))
        #expect(urls.contains("https://github.com/dodo-reach/apple-pi"))
    }
}
