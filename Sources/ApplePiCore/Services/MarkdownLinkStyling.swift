import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shared inline-Markdown → AttributedString conversion for chat bubbles.
///
/// The plain `AttributedString(markdown:)` parse already handles `[label](url)`
/// links, but two gaps made links in chat effectively invisible:
///
/// 1. Bare URLs (`https://…`) are not part of inline Markdown syntax, so they
///    stayed plain, non-clickable text. Chat output is full of raw URLs, so we
///    autolink them with NSDataDetector while skipping inline code spans and
///    ranges already covered by explicit Markdown links.
/// 2. Bubbles apply their own `.foregroundStyle(textColor)` at the view level,
///    which overrides SwiftUI's default link tint. We therefore bake an
///    explicit accent color + underline into every link run, so links stay
///    visibly highlighted regardless of surrounding styling.
public enum MarkdownLinkStyling {

    /// Parses inline Markdown and returns an attributed string whose link runs
    /// are visibly highlighted and carry a resolvable `.link` attribute.
    /// Returns `nil` when Markdown parsing itself fails.
    public static func parseInline(_ markdown: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: markdown, options: options) else {
            return nil
        }
        autolinkBareURLs(in: &attributed)
        styleLinkRuns(in: &attributed)
        return attributed
    }

    /// Opens a chat link with the system handler (default browser, mail app…).
    public static func openExternally(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Bare URL autolinking

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func autolinkBareURLs(in attributed: inout AttributedString) {
        guard let detector = linkDetector else { return }
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return }
        let fullRange = NSRange(plain.startIndex..., in: plain)

        // Explicit Markdown link destinations always win over detector guesses.
        let explicitLinkRanges: [NSRange] = attributed.runs.compactMap { run in
            guard run.link != nil else { return nil }
            return NSRange(run.range, in: attributed)
        }

        detector.enumerateMatches(in: plain, range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            let matchRange = match.range
            let overlapsExplicitLink = explicitLinkRanges.contains {
                NSIntersectionRange($0, matchRange).length > 0
            }
            guard !overlapsExplicitLink,
                  let range = Range(matchRange, in: attributed) else { return }
            // URLs inside inline code spans stay plain code text.
            let insideCode = attributed[range].runs.contains {
                $0.inlinePresentationIntent?.contains(.code) == true
            }
            guard !insideCode else { return }
            attributed[range].link = url
        }
    }

    // MARK: - Link highlighting

    private static func styleLinkRuns(in attributed: inout AttributedString) {
        let linkRanges: [Range<AttributedString.Index>] = attributed.runs.compactMap { run in
            guard run.link != nil else { return nil }
            return run.range
        }
        for range in linkRanges {
            attributed[range].foregroundColor = LinkStyle.color
            attributed[range].underlineStyle = .single
        }
    }
}

#if canImport(AppKit)
private enum LinkStyle {
    static let color = NSColor.controlAccentColor
}
#elseif canImport(UIKit)
private enum LinkStyle {
    static let color = UIColor.tintColor
}
#endif
