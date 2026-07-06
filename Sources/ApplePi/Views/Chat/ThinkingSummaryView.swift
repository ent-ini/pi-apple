import SwiftUI
import ApplePiCore
import ApplePiRemote

/// Renders the assistant's `thinking` content as a compact single-line
/// disclosure row. Collapsed state shows only the word `Thinking`; expanded
/// state reveals the full text at its natural height.
struct ThinkingSummaryView: View {
    @Environment(\.chatEnsureVisible) private var ensureVisible
    let thinkingText: String
    let visibilityID: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let willExpand = !isExpanded
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
                if willExpand {
                    ensureVisible(visibilityID)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide thinking" : "Show thinking")

            if isExpanded {
                MarkdownText(thinkingText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .chatVisibilityTarget(visibilityID)
    }
}
