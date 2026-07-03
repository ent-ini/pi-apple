import SwiftUI
#if os(macOS)
import AppKit
#endif
import ApplePiCore
import ApplePiRemote

/// Scrollable list of `SessionEvent`s. Renders message bubbles for chat
/// turns and compact disclosure rows for tool calls, tool results, and
/// non-message bookkeeping events (session meta, labels, branch summaries,
/// custom entries). As new events arrive the list auto-scrolls to the
/// bottom, but only if the user is already near the bottom (so reading
/// older messages does not get hijacked by streaming).
struct MessageListView: View {
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var session: ChatSession

    @State private var isAnchoredToBottom = true
    @State private var stickyAutoScrollUntil: Date?
    @State private var hasCompletedInitialPlacement = false
    @State private var bottomScrollWorkItems: [DispatchWorkItem] = []
    @State private var ensureVisibleWorkItems: [DispatchWorkItem] = []
    @State private var bottomScrollGeneration = 0
    @State private var ensureVisibleGeneration = 0
    @State private var recentUserScrollUntil: Date?
    @State private var historyLoadRowMinY: CGFloat = .greatestFiniteMagnitude
    @State private var displayedRowsCache: [DisplayedSessionRow] = []
    @State private var fileReferenceBaseDirectoryCache: String?

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.hasEarlierHistory || session.isLoadingEarlierHistory {
                            historyLoadRow
                        }
                        ForEach(displayedRowsCache) { row in
                            DisplayedSessionRowView(
                                row: row,
                                fileReferenceBaseDirectory: fileReferenceBaseDirectoryCache
                            )
                            .equatable()
                            .id(row.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .background {
                                GeometryReader { anchorProxy in
                                    Color.clear
                                        .preference(
                                            key: BottomAnchorMaxYPreferenceKey.self,
                                            value: anchorProxy.frame(in: .named(Self.scrollCoordinateSpaceName)).maxY
                                        )
                                }
                            }
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                .background(
                    ChatScrollIntentObserver {
                        noteUserScrollIntent()
                    }
                )
                .environment(\.chatEnsureVisible, ChatEnsureVisibleAction { targetID in
                    ensureVisible(targetID, using: scrollProxy, viewportHeight: proxy.size.height)
                })
                .onPreferenceChange(BottomAnchorMaxYPreferenceKey.self) { bottomMaxY in
                    updateBottomAnchoring(
                        bottomMaxY: bottomMaxY,
                        viewportHeight: proxy.size.height,
                        scrollProxy: scrollProxy
                    )
                }
                .onPreferenceChange(HistoryLoadRowMinYPreferenceKey.self) { minY in
                    historyLoadRowMinY = minY
                    autoLoadEarlierHistoryIfUserScrolledNearTop()
                }
                .onChange(of: session.streamRevision) { _, _ in
                    refreshDisplayedRowsCache()
                    scheduleScrollToBottomIfNeeded(using: scrollProxy)
                }
                .onChange(of: session.historyRevision) { _, _ in
                    refreshDisplayedRowsCache()
                    if let anchorID = session.consumePendingHistoryAnchorID() {
                        scrollProxy.scrollTo(anchorID, anchor: .top)
                    }
                }
                .onChange(of: session.isSending) { _, isSending in
                    guard isSending else { return }
                    refreshDisplayedRowsCache()
                    startStickyAutoScroll()
                    scheduleScrollToBottomSettled(using: scrollProxy, animated: false, completesInitialPlacement: false)
                }
                .onChange(of: session.isLoading) { _, isLoading in
                    guard !isLoading else { return }
                    refreshDisplayedRowsCache()
                    if !hasCompletedInitialPlacement || isAnchoredToBottom {
                        scheduleScrollToBottomSettled(
                            using: scrollProxy,
                            animated: false,
                            completesInitialPlacement: !hasCompletedInitialPlacement
                        )
                    }
                }
                .onAppear {
                    hasCompletedInitialPlacement = false
                    refreshDisplayedRowsCache()
                    if session.isLoading {
                        return
                    }
                    scrollToBottomSettled(using: scrollProxy, animated: false, completesInitialPlacement: true)
                }
                .onDisappear {
                    cancelBottomScrollWorkItems()
                    cancelEnsureVisibleWorkItems()
                }
            }
        }
    }

    private static let bottomAnchorID = "chat.list.bottom"
    static let scrollCoordinateSpaceName = "chat.list.scroll"
    private static let bottomStickinessBuffer: CGFloat = 180
    private static let historyAutoLoadDistance: CGFloat = 280
    // Streaming can grow the transcript by more than a few pixels before the
    // next scroll-to-bottom pass runs. Keep enough slack to stay pinned when the
    // user was already at the bottom, while still letting an intentional scroll
    // up break away from the live tail.
    private static let stickyBreakawayDistance: CGFloat = 260
    private static let bottomReachedEpsilon: CGFloat = 3
    private static let stickyAutoScrollDuration: TimeInterval = 30
    private static let recentUserScrollDuration: TimeInterval = 0.9
    private static let userScrollBreakawayDistance: CGFloat = 12
    private static let historyPageSize = 40
    private static let scrollSettleDelays: [TimeInterval] = [0.0, 0.08, 0.22]
    private static let ensureVisibleSettleDelays: [TimeInterval] = [0.04, 0.16, 0.34, 0.65]

    private func refreshDisplayedRowsCache() {
        let allEvents = session.events
        // `ChatSession` is the single source of transcript order: persisted
        // rows are merged by JSONL/source order, while live/optimistic rows are
        // append-only in the order the user/app observed them. Do not sort here:
        // a view-level sort can move retained transient rows around after
        // abort/steer/follow-up transitions and make already-visible messages
        // appear to jump.
        displayedRowsCache = DisplayedSessionRow.groupingToolResults(in: allEvents.filter(\.isVisibleInTranscript))
        fileReferenceBaseDirectoryCache = resolveFileReferenceBaseDirectory(from: allEvents)
    }

    private func resolveFileReferenceBaseDirectory(from events: [SessionEvent]) -> String? {
        if let workingDirectory = session.launchRequest?.workingDirectory?.nilIfBlank {
            return workingDirectory
        }
        if let workingDirectory = events.compactMap({ event -> String? in
            if case .meta(let meta, _) = event {
                return meta.workingDirectory?.nilIfBlank
            }
            return nil
        }).last {
            return workingDirectory
        }
        if let sessionID = session.sessionID,
           let summary = appState.sessions.first(where: { $0.id == sessionID || $0.filePath == sessionID }),
           let workingDirectory = summary.workingDirectory?.nilIfBlank {
            return workingDirectory
        }
        if let configured = appState.host.defaultWorkingDirectory.nilIfBlank {
            return configured
        }
        if let path = session.sessionPath?.nilIfBlank {
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return nil
    }

    @ViewBuilder
    private var historyLoadRow: some View {
        HStack {
            Spacer()
            if session.isLoadingEarlierHistory {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading earlier messages")
            } else {
                Button("Load earlier messages") {
                    loadEarlierHistoryPage()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background {
            GeometryReader { historyProxy in
                Color.clear.preference(
                    key: HistoryLoadRowMinYPreferenceKey.self,
                    value: historyProxy.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
                )
            }
        }
        .id("history-load-\(session.firstPersistedLineIndex)")
    }

    private func loadEarlierHistoryPage() {
        loadEarlierHistoryPage(userInitiated: true)
    }

    private func loadEarlierHistoryPage(userInitiated: Bool) {
        guard session.hasEarlierHistory,
              !session.isLoadingEarlierHistory else {
            return
        }
        session.loadEarlierHistory(limit: Self.historyPageSize, preserveVisiblePosition: userInitiated)
    }

    private func autoLoadEarlierHistoryIfUserScrolledNearTop() {
        guard isRecentUserScrollActive,
              historyLoadRowMinY.isFinite,
              historyLoadRowMinY >= -Self.historyAutoLoadDistance,
              historyLoadRowMinY <= Self.historyAutoLoadDistance else {
            return
        }
        loadEarlierHistoryPage(userInitiated: true)
    }

    private var isStickyAutoScrollActive: Bool {
        guard let stickyAutoScrollUntil else { return false }
        return stickyAutoScrollUntil > Date()
    }

    private func updateBottomAnchoring(
        bottomMaxY: CGFloat,
        viewportHeight: CGFloat,
        scrollProxy: ScrollViewProxy
    ) {
        guard bottomMaxY.isFinite,
              bottomMaxY < .greatestFiniteMagnitude / 2 else {
            return
        }
        let distanceToBottom = bottomMaxY - viewportHeight
        if isStickyAutoScrollActive {
            if isRecentUserScrollActive, distanceToBottom > Self.userScrollBreakawayDistance {
                stickyAutoScrollUntil = nil
                isAnchoredToBottom = false
                cancelBottomScrollWorkItems()
                return
            }
            if distanceToBottom > Self.stickyBreakawayDistance {
                stickyAutoScrollUntil = nil
                isAnchoredToBottom = false
                cancelBottomScrollWorkItems()
                return
            }
            isAnchoredToBottom = true
            if distanceToBottom > Self.bottomReachedEpsilon, bottomScrollWorkItems.isEmpty {
                scrollToBottomSettled(using: scrollProxy, animated: false, completesInitialPlacement: false)
            }
            return
        }
        isAnchoredToBottom = distanceToBottom <= Self.bottomStickinessBuffer
    }

    private func scheduleScrollToBottomIfNeeded(using scrollProxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            scrollToBottomIfNeeded(using: scrollProxy)
        }
    }

    private func scheduleScrollToBottomSettled(using scrollProxy: ScrollViewProxy, animated: Bool, completesInitialPlacement: Bool) {
        DispatchQueue.main.async {
            scrollToBottomSettled(using: scrollProxy, animated: animated, completesInitialPlacement: completesInitialPlacement)
        }
    }

    private func scrollToBottomIfNeeded(using scrollProxy: ScrollViewProxy) {
        guard isAnchoredToBottom || isStickyAutoScrollActive else { return }
        startStickyAutoScroll()
        scrollToBottomSettled(using: scrollProxy, animated: false, completesInitialPlacement: false)
    }

    private var isRecentUserScrollActive: Bool {
        guard let recentUserScrollUntil else { return false }
        return recentUserScrollUntil > Date()
    }

    private func noteUserScrollIntent() {
        recentUserScrollUntil = Date().addingTimeInterval(Self.recentUserScrollDuration)
        autoLoadEarlierHistoryIfUserScrolledNearTop()
    }

    private func startStickyAutoScroll() {
        guard Self.stickyAutoScrollDuration > 0 else {
            stickyAutoScrollUntil = nil
            return
        }
        stickyAutoScrollUntil = Date().addingTimeInterval(Self.stickyAutoScrollDuration)
    }

    private func scrollToBottom(using scrollProxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func scrollToBottomSettled(using scrollProxy: ScrollViewProxy, animated: Bool, completesInitialPlacement: Bool) {
        cancelEnsureVisibleWorkItems()
        cancelBottomScrollWorkItems()
        bottomScrollGeneration &+= 1
        let generation = bottomScrollGeneration

        let workItems = Self.scrollSettleDelays.enumerated().map { index, delay in
            let item = DispatchWorkItem {
                guard bottomScrollGeneration == generation else { return }
                scrollToBottom(using: scrollProxy, animated: animated && index == 0)
                if index == Self.scrollSettleDelays.count - 1 {
                    if completesInitialPlacement {
                        hasCompletedInitialPlacement = true
                    }
                    if bottomScrollGeneration == generation {
                        bottomScrollWorkItems = []
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
        bottomScrollWorkItems = workItems
    }

    private func ensureVisible(_ targetID: String, using scrollProxy: ScrollViewProxy, viewportHeight _: CGFloat) {
        stickyAutoScrollUntil = nil
        cancelBottomScrollWorkItems()
        cancelEnsureVisibleWorkItems()
        ensureVisibleGeneration &+= 1
        let generation = ensureVisibleGeneration

        let workItems = Self.ensureVisibleSettleDelays.enumerated().map { index, delay in
            let item = DispatchWorkItem {
                guard ensureVisibleGeneration == generation else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    scrollProxy.scrollTo(targetID, anchor: .top)
                }
                if index == Self.ensureVisibleSettleDelays.count - 1,
                   ensureVisibleGeneration == generation {
                    ensureVisibleWorkItems = []
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
        ensureVisibleWorkItems = workItems
    }

    private func cancelBottomScrollWorkItems() {
        bottomScrollGeneration &+= 1
        bottomScrollWorkItems.forEach { $0.cancel() }
        bottomScrollWorkItems = []
    }

    private func cancelEnsureVisibleWorkItems() {
        ensureVisibleGeneration &+= 1
        ensureVisibleWorkItems.forEach { $0.cancel() }
        ensureVisibleWorkItems = []
    }
}

// MARK: - Display rows

private struct BottomAnchorMaxYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HistoryLoadRowMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#if os(macOS)
private struct ChatScrollIntentObserver: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ChatScrollIntentView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ChatScrollIntentView)?.onUserScroll = onUserScroll
    }
}

private final class ChatScrollIntentView: NSView {
    var onUserScroll: (() -> Void)?
    private var monitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetMonitor()
    }

    private func resetMonitor() {
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.eventIsInsideView(event) else { return event }
            self.onUserScroll?()
            return event
        }
    }

    private func eventIsInsideView(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            removeMonitor()
        }
    }
}
#else
private struct ChatScrollIntentObserver: View {
    let onUserScroll: () -> Void
    var body: some View { Color.clear }
}
#endif

struct ChatEnsureVisibleAction: @unchecked Sendable {
    let action: @MainActor (String) -> Void

    @MainActor
    func callAsFunction(_ targetID: String) {
        action(targetID)
    }
}

private struct ChatEnsureVisibleEnvironmentKey: EnvironmentKey {
    static let defaultValue = ChatEnsureVisibleAction { _ in }
}

extension EnvironmentValues {
    var chatEnsureVisible: ChatEnsureVisibleAction {
        get { self[ChatEnsureVisibleEnvironmentKey.self] }
        set { self[ChatEnsureVisibleEnvironmentKey.self] = newValue }
    }
}

extension View {
    func chatVisibilityTarget(_ id: String) -> some View {
        self.id(id)
    }
}

private struct DisplayedSessionRowView: View, Equatable {
    let row: DisplayedSessionRow
    let fileReferenceBaseDirectory: String?

    nonisolated static func == (lhs: DisplayedSessionRowView, rhs: DisplayedSessionRowView) -> Bool {
        lhs.row == rhs.row && lhs.fileReferenceBaseDirectory == rhs.fileReferenceBaseDirectory
    }

    var body: some View {
        switch row {
        case .event(let event):
            switch event {
            case .message(let message, _):
                MessageBubble(message: message, fileReferenceBaseDirectory: fileReferenceBaseDirectory)
            case .toolCall(let call, _):
                ToolInteractionRow(
                    name: call.name,
                    arguments: call.arguments,
                    result: nil,
                    visibilityID: "visibility:\(event.id)"
                )
            case .toolResult(let result, _):
                ToolEventRow(
                    kind: .toolResult(
                        name: result.toolName,
                        callId: result.callId,
                        output: result.output,
                        isError: result.isError
                    ),
                    visibilityID: "visibility:\(event.id)"
                )
            case .meta(let meta, _):
                ToolEventRow(
                    kind: .meta(
                        displayName: meta.displayName,
                        workingDirectory: meta.workingDirectory,
                        parentSession: meta.parentSession
                    ),
                    visibilityID: "visibility:\(event.id)"
                )
            case .other(let type, _):
                ToolEventRow(kind: .other(type: type), visibilityID: "visibility:\(event.id)")
            }
        case .toolInteraction(let call, let result, _):
            ToolInteractionRow(
                name: call.name,
                arguments: call.arguments,
                result: result,
                visibilityID: "visibility:\(row.id)"
            )
        }
    }
}

private enum DisplayedSessionRow: Identifiable, Hashable {
    case event(SessionEvent)
    case toolInteraction(call: ToolCall, result: ToolResult?, lineIndex: Int)

    var id: String {
        switch self {
        case .event(let event):
            return event.id
        case .toolInteraction(let call, _, _):
            return "toolInteraction:\(call.id)"
        }
    }

    static func groupingToolResults(in events: [SessionEvent]) -> [DisplayedSessionRow] {
        var resultByCallID: [String: ToolResult] = [:]
        var callIDs = Set<String>()

        for event in events {
            switch event {
            case .toolCall(let call, _):
                callIDs.insert(call.id)
            case .toolResult(let result, _):
                guard !result.callId.isEmpty else { continue }
                // Tool results may stream more than once for the same call.
                // Keep the latest payload attached to the original call row
                // so the transcript order stays call -> result -> answer.
                resultByCallID[result.callId] = result
            case .message, .meta, .other:
                continue
            }
        }

        let pairedCallIDs = Set(callIDs.filter { resultByCallID[$0] != nil })
        return events.compactMap { event in
            switch event {
            case .toolCall(let call, let lineIndex):
                return .toolInteraction(call: call, result: resultByCallID[call.id], lineIndex: lineIndex)
            case .toolResult(let result, _):
                if pairedCallIDs.contains(result.callId) { return nil }
                return .event(event)
            case .message, .meta, .other:
                return .event(event)
            }
        }
    }
}

// MARK: - ToolInteractionRow

/// Paired tool invocation and response. Shows the model's call arguments
/// first, then the tool output underneath, so a transcript reads like:
///
///     tool · bash
///     Call      {"command":"crontab -l"}
///     Response  Current crontab: ...
struct ToolInteractionRow: View {
    @Environment(\.chatEnsureVisible) private var ensureVisible
    let name: String
    let arguments: String
    let result: ToolResult?
    let visibilityID: String

    @State private var isExpanded: Bool

    init(name: String, arguments: String, result: ToolResult?, visibilityID: String) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.visibilityID = visibilityID
        _isExpanded = State(initialValue: false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
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
                        Image(systemName: toolIconName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(result?.isError == true ? .red : .secondary)
                        Text(toolLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse long tool details" : "Expand full tool call and response")

                if isExpanded {
                    if name == "edit", let diff = editDiff {
                        if let summary = editSummary?.nilIfBlank {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        GitDiffView(diffText: diff, filePath: editPath)
                    } else {
                        toolSection(title: "Call", text: arguments, fallback: "(no arguments)")
                        if let result {
                            toolSection(title: "Response", text: result.output, fallback: "(empty)")
                        } else {
                            toolSection(title: "Response", text: "", fallback: "(waiting for tool result)")
                        }
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 10 : 0)
            .padding(.vertical, isExpanded ? 8 : 0)
            .frame(maxWidth: 620, alignment: .leading)
            .background {
                if isExpanded {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
            Spacer(minLength: 60)
        }
        .chatVisibilityTarget(visibilityID)
    }

    @ViewBuilder
    private func toolSection(title: String, text: String, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(displayText(text, fallback: fallback))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
        }
    }

    private var toolIconName: String {
        if result?.isError == true { return "exclamationmark.triangle" }
        if name == "edit" { return "doc.text.magnifyingglass" }
        return "wrench.and.screwdriver"
    }

    private var toolLabel: String {
        var parts = ["tool", name]
        if name == "edit", let editPath {
            parts.append(URL(fileURLWithPath: editPath).lastPathComponent.nilIfBlank ?? editPath)
        }
        if result?.isError == true {
            parts.append("error")
        }
        return parts.joined(separator: " · ")
    }

    private var editPath: String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String else {
            return nil
        }
        return path
    }

    private var editSummary: String? {
        Self.splitDiff(from: result?.output).summary
    }

    private var editDiff: String? {
        Self.splitDiff(from: result?.output).diff
    }

    private static func splitDiff(from output: String?) -> (summary: String?, diff: String?) {
        guard let output else { return (nil, nil) }
        guard let range = output.range(of: toolResultDiffSeparator) else {
            return (output, nil)
        }
        let summary = String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary.isEmpty ? nil : summary, diff.isEmpty ? nil : diff)
    }

    private func displayText(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private struct GitDiffView: View {
    let diffText: String
    let filePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let filePath = filePath?.nilIfBlank {
                diffLine("diff -- \(filePath)", kind: .header)
                diffLine("--- a/\(filePath)", kind: .header)
                diffLine("+++ b/\(filePath)", kind: .header)
            }
            ForEach(Array(diffText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                let text = String(line)
                diffLine(text, kind: DiffLineKind(text))
            }
        }
        .textSelection(.enabled)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func diffLine(_ text: String, kind: DiffLineKind) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.caption.monospaced())
            .foregroundStyle(kind.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1.5)
            .background(kind.background)
    }
}

private enum DiffLineKind {
    case insertion
    case deletion
    case header
    case hunk
    case context

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("diff ") { self = .header }
        else if text.hasPrefix("+") || trimmed.range(of: #"^\d+\s+\+"#, options: .regularExpression) != nil { self = .insertion }
        else if text.hasPrefix("-") || trimmed.range(of: #"^\d+\s+-"#, options: .regularExpression) != nil { self = .deletion }
        else if text.hasPrefix("@@") || trimmed.hasPrefix("...") { self = .hunk }
        else { self = .context }
    }

    var foreground: Color {
        switch self {
        case .insertion: return .green
        case .deletion: return .red
        case .header, .hunk: return .secondary
        case .context: return .primary.opacity(0.78)
        }
    }

    var background: Color {
        switch self {
        case .insertion: return Color.green.opacity(0.12)
        case .deletion: return Color.red.opacity(0.12)
        case .header, .hunk: return Color.primary.opacity(0.04)
        case .context: return .clear
        }
    }
}

// MARK: - ToolEventRow

/// Compact, single-line disclosure for non-message events: tool calls,
/// tool results, session meta, and bookkeeping entries (label changes,
/// branch summaries, custom messages, etc.). The row stays out of the
/// way but the user can expand it to inspect raw payloads.
struct ToolEventRow: View {
    enum Kind {
        case toolCall(name: String, arguments: String)
        case toolResult(name: String?, callId: String, output: String, isError: Bool)
        case meta(displayName: String?, workingDirectory: String?, parentSession: String?)
        case other(type: String)

        var label: String {
            switch self {
            case .toolCall(let name, _):
                return "tool · \(name)"
            case .toolResult(let name, _, _, let isError):
                let display = name.map { "tool · \($0)" } ?? "tool result"
                return isError ? "\(display) · error" : display
            case .meta(let displayName, let cwd, _):
                var parts: [String] = ["session"]
                if let displayName, !displayName.isEmpty { parts.append(displayName) }
                if let cwd, !cwd.isEmpty { parts.append(cwd) }
                return parts.joined(separator: " · ")
            case .other(let type):
                return "event · \(type)"
            }
        }

        var iconName: String {
            switch self {
            case .toolCall: return "wrench.and.screwdriver"
            case .toolResult(_, _, _, let isError):
                return isError ? "exclamationmark.triangle" : "checkmark.circle"
            case .meta: return "info.circle"
            case .other: return "doc.text"
            }
        }

        var tint: Color {
            switch self {
            case .toolCall: return .secondary
            case .toolResult(_, _, _, let isError):
                return isError ? .red : .secondary
            case .meta: return .secondary
            case .other: return .secondary
            }
        }

        var expandedBody: String? {
            switch self {
            case .toolCall(_, let arguments):
                return arguments.isEmpty ? nil : arguments
            case .toolResult(_, _, let output, _):
                return output.isEmpty ? nil : output
            case .meta(let displayName, let cwd, let parent):
                var pieces: [String] = []
                if let displayName, !displayName.isEmpty { pieces.append("name: \(displayName)") }
                if let cwd, !cwd.isEmpty { pieces.append("cwd: \(cwd)") }
                if let parent, !parent.isEmpty { pieces.append("parent: \(parent)") }
                return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
            case .other:
                return nil
            }
        }

    }

    @Environment(\.chatEnsureVisible) private var ensureVisible
    let kind: Kind
    let visibilityID: String

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            row
                .frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: 60)
        }
    }

    @ViewBuilder
    private var row: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard kind.expandedBody != nil else { return }
                let willExpand = !isExpanded
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
                if willExpand {
                    ensureVisible(visibilityID)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(kind.tint)
                    Text(kind.label)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if kind.expandedBody != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(kind.expandedBody == nil ? kind.label : (isExpanded ? "Hide details" : "Show details"))

            if isExpanded, let body = kind.expandedBody {
                Text(body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, isExpanded ? 10 : 0)
        .padding(.vertical, isExpanded ? 6 : 0)
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .chatVisibilityTarget(visibilityID)
    }
}
