import SwiftUI
import ApplePiCore

struct MobileRootView: View {
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var showsSettings = false
    @State private var showsChat = false

    var body: some View {
        NavigationStack {
            MobileSessionListView {
                showsChat = true
            }
            .navigationTitle("pi-app")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        appState.startNewSession()
                        showsChat = true
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }

                    Button {
                        Task { await appState.reloadCatalog() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isLoadingCatalog)

                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $showsChat) {
                MobileSessionDetailView()
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                MobileSettingsView()
                    .navigationTitle("Remote API")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showsSettings = false
                                Task {
                                    await appState.reloadCatalog()
                                    appState.startCatalogStream()
                                }
                            }
                        }
                    }
            }
        }
    }
}

private struct MobileSessionListView: View {
    @EnvironmentObject private var appState: MobilePiAppState
    let onOpenDetail: () -> Void

    var body: some View {
        List(selection: selectedSessionBinding) {
            if !appState.isConfigured {
                ContentUnavailableView(
                    "Remote API required",
                    systemImage: "network",
                    description: Text("Open settings and enter your pi-appd URL.")
                )
            } else if appState.isLoadingCatalog && appState.sessions.isEmpty {
                ProgressView("Loading sessions…")
            } else if appState.sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(appState.statusMessage)
                )
            } else {
                Section("Sessions") {
                    ForEach(appState.sessions) { session in
                        Button {
                            onOpenDetail()
                            Task { await appState.selectSession(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(session.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Label("\(session.messageCount)", systemImage: "text.bubble")
                                    if let model = session.latestModel {
                                        Text(model)
                                    }
                                    if session.isGenerating || (appState.isSending && appState.selectedSession?.id == session.id) {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
    }

    private var selectedSessionBinding: Binding<String?> {
        Binding(
            get: { appState.selectedSession?.id },
            set: { _ in }
        )
    }
}

private struct MobileSessionDetailView: View {
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        VStack(spacing: 0) {
            if let session = appState.selectedSession {
                transcript(for: session)
                Divider()
                composer
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "message",
                    description: Text("Or type a prompt below to start a new remote session.")
                )
                Divider()
                composer
            }
        }
        .navigationTitle(appState.selectedSession?.title ?? "New Session")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isLoadingSession {
                    ProgressView()
                }
                Button {
                    appState.startNewSession()
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }

                Button {
                    Task { await appState.reloadSelectedSession() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(appState.selectedSession == nil || appState.isLoadingSession)
            }
        }
    }

    private func transcript(for session: PiSessionSummary) -> some View {
        let rows = MobileDisplayedRow.groupingToolResults(in: appState.filteredVisibleEvents)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        MobileEventRow(row: row)
                            .id(row.id)
                    }
                }
                .padding()
            }
            .overlay {
                if appState.isLoadingSession && appState.selectedEvents.isEmpty {
                    ProgressView("Loading \(session.title)…")
                }
            }
            .onChange(of: rows.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message pi…", text: $appState.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Button {
                Task { await appState.sendDraft() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
}

private enum MobileDisplayedRow: Identifiable, Hashable {
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

    static func groupingToolResults(in events: [SessionEvent]) -> [MobileDisplayedRow] {
        var resultByCallID: [String: ToolResult] = [:]
        var callIDs = Set<String>()

        for event in events {
            switch event {
            case .toolCall(let call, _):
                callIDs.insert(call.id)
            case .toolResult(let result, _):
                guard !result.callId.isEmpty else { continue }
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

private struct MobileEventRow: View {
    let row: MobileDisplayedRow

    var body: some View {
        switch row {
        case .event(let event):
            switch event {
            case .message(let message, _):
                MessageBubble(message: message)
            case .toolCall(let call, _):
                ToolBlock(title: "tool · \(call.name)", sections: [("Call", call.arguments)])
            case .toolResult(let result, _):
                ToolBlock(title: result.toolName ?? "Tool result", sections: [("Response", result.output)], isError: result.isError)
            case .other(let type, _):
                ToolBlock(title: type, sections: [])
            case .meta:
                EmptyView()
            }
        case .toolInteraction(let call, let result, _):
            ToolBlock(
                title: "tool · \(call.name)",
                sections: [
                    ("Call", call.arguments),
                    ("Response", result?.output ?? "(waiting for tool result)")
                ],
                isError: result?.isError == true
            )
        }
    }
}

private struct MessageBubble: View {
    let message: Message

    var body: some View {
        if shouldRenderRow {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 32)
                    bubbleColumn(alignment: .trailing)
                } else {
                    bubbleColumn(alignment: .leading)
                    Spacer(minLength: 32)
                }
            }
        }
    }

    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if !thinkingText.isEmpty {
                MobileThinkingSummaryView(thinkingText: thinkingText)
            }
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                bubbleSurface {
                    MarkdownMessageText(markdown: trimmed)
                }
            }
        case .thinking:
            EmptyView()
        case .image(let path, let mime):
            bubbleSurface {
                if let mime {
                    Text("[image: \(path), \(mime)]")
                } else {
                    Text("[image: \(path)]")
                }
            }
        }
    }

    private func bubbleSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var visibleBlocks: [ContentBlock] {
        message.content.filter {
            if case .thinking = $0 { return false }
            return true
        }
    }

    private var thinkingText: String {
        message.content.compactMap { block in
            if case .thinking(let text, _) = block {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n---\n\n")
    }

    private var shouldRenderRow: Bool {
        !thinkingText.isEmpty || !visibleBlocks.isEmpty
    }
}

private struct MarkdownMessageText: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .textSelection(.enabled)
        }
    }
}

private struct MobileThinkingSummaryView: View {
    let thinkingText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
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

            if isExpanded {
                Text(thinkingText)
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ToolBlock: View {
    let title: String
    let sections: [(label: String, text: String)]
    var isError = false
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isError ? .red : .secondary)
                        Text(title)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    if sections.isEmpty {
                        Text("(no details)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            toolSection(title: section.label, text: section.text)
                        }
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 10 : 0)
            .padding(.vertical, isExpanded ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isExpanded {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                }
            }
            Spacer(minLength: 32)
        }
    }

    private func toolSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
        }
    }
}

private struct MobileSettingsView: View {
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        Form {
            Section("pi-appd") {
                TextField("http://100.100.20.10:8787", text: $appState.daemonURL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Bearer token", text: $appState.daemonToken)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }

            Section {
                Button("Test Connection") {
                    Task { await appState.testConnection() }
                }
                Button("Reload Catalog") {
                    Task { await appState.reloadCatalog() }
                }
            }

            Section("Status") {
                Text(appState.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension Message {
    var plainText: String {
        content.map { block in
            switch block {
            case .text(let value):
                return value
            case .thinking(let value, _):
                return value
            case .image(let path, let mime):
                if let mime {
                    return "[image: \(path), \(mime)]"
                }
                return "[image: \(path)]"
            }
        }
        .joined(separator: "\n")
    }
}
