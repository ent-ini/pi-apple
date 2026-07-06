import SwiftUI
import ApplePiCore

struct MobileRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var showsSettings = false
    @State private var showsChat = false

    var body: some View {
        NavigationStack {
            MobileSessionListView(
                showsSettings: $showsSettings,
                onOpenDetail: { showsChat = true }
            )
            .navigationDestination(isPresented: $showsChat) {
                MobileSessionDetailView()
            }
            .hiddenMobileNavigationBar()
        }
        .tint(MobileTheme.accentColor)
        .preferredColorScheme(colorScheme)
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
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @Binding var showsSettings: Bool
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)

            Divider().opacity(0.24)

            content
        }
        .foregroundStyle(MobileTheme.textColor(for: colorScheme))
        .background(MobileTheme.sidebarBackgroundColor(for: colorScheme).ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            MobileSearchField(text: $appState.sessionSearchText)

            MobileIconButton(systemName: "square.and.pencil", help: "New session") {
                appState.startNewSession()
                onOpenDetail()
            }

            MobileIconButton(systemName: "arrow.clockwise", help: "Refresh sessions", isDisabled: appState.isLoadingCatalog) {
                Task { await appState.reloadCatalog() }
            }

            MobileIconButton(systemName: "gearshape", help: "Settings") {
                showsSettings = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !appState.isConfigured {
            ContentUnavailableView(
                "Remote API required",
                systemImage: "network",
                description: Text("Open settings and enter your pi-appd URL.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.isLoadingCatalog && appState.sessions.isEmpty {
            ProgressView("Loading sessions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.filteredSessions.isEmpty {
            ContentUnavailableView(
                appState.sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No sessions" : "No matches",
                systemImage: appState.sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                description: Text(appState.sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appState.statusMessage : appState.sessionSearchText)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.filteredSessions) { session in
                        Button {
                            onOpenDetail()
                            Task { await appState.selectSession(session) }
                        } label: {
                            MobileSessionRow(
                                session: session,
                                isSelected: appState.selectedSession?.id == session.id,
                                isSending: session.isGenerating || (appState.isSending && appState.selectedSession?.id == session.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct MobileSessionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: PiSessionSummary
    let isSelected: Bool
    let isSending: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MobileTheme.textColor(for: colorScheme))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(session.modifiedAt, style: .date)
                        Label("\(session.messageCount)", systemImage: "text.bubble")
                        if let model = session.latestModel {
                            Text(model)
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MobileTheme.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? MobileTheme.controlTint(for: colorScheme, opacity: 0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()
                .padding(.leading, 12)
                .opacity(isSelected ? 0 : 0.28)
        }
    }
}

private struct MobileSessionDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        VStack(spacing: 0) {
            chatTopBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

            Divider().opacity(0.24)

            if let session = appState.selectedSession {
                transcript(for: session)
            } else {
                ContentUnavailableView(
                    "New session",
                    systemImage: "message",
                    description: Text("Type a prompt below to start a remote session.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            composer
        }
        .foregroundStyle(MobileTheme.textColor(for: colorScheme))
        .background(MobileTheme.mainBackgroundColor(for: colorScheme).ignoresSafeArea())
        .hiddenMobileNavigationBar()
        .task(id: appState.selectedSession?.id) {
            await appState.refreshSelectedRuntimeAndModels()
        }
    }

    private var chatTopBar: some View {
        HStack(spacing: 8) {
            MobileIconButton(systemName: "chevron.left", help: "Back") {
                dismiss()
            }

            sessionTitleMenu

            Spacer(minLength: 0)

            if appState.isLoadingSession || appState.isLoadingRuntime {
                ProgressView()
                    .controlSize(.small)
                    .tint(MobileTheme.accentColor)
            }

            MobileIconButton(systemName: "square.and.pencil", help: "New session") {
                appState.startNewSession()
            }

            MobileIconButton(systemName: "arrow.clockwise", help: "Reload session", isDisabled: appState.selectedSession == nil || appState.isLoadingSession) {
                Task { await appState.reloadSelectedSession() }
            }
        }
    }

    private var sessionTitleMenu: some View {
        Menu {
            if appState.selectedSession == nil {
                Text("No active session yet")
            } else {
                Menu {
                    if groupedModels.isEmpty {
                        Text("Loading models…")
                    } else {
                        ForEach(groupedModels) { group in
                            Section(group.provider) {
                                ForEach(group.models) { model in
                                    Button {
                                        Task { await appState.setSelectedModel(model) }
                                    } label: {
                                        if appState.selectedRuntime?.provider == model.provider,
                                           appState.selectedRuntime?.modelID == model.modelID {
                                            Label(model.shortLabel, systemImage: "checkmark")
                                        } else {
                                            Text(model.shortLabel)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(appState.selectedModelDisplayName, systemImage: "cpu")
                }

                Menu {
                    ForEach(MobilePiAppState.thinkingLevels, id: \.self) { level in
                        Button {
                            Task { await appState.setSelectedThinkingLevel(level) }
                        } label: {
                            if appState.selectedThinkingLevel == level {
                                Label(level, systemImage: "checkmark")
                            } else {
                                Text(level)
                            }
                        }
                    }
                } label: {
                    Label(appState.selectedThinkingLevel, systemImage: "brain")
                }

                Divider()

                Button("Refresh runtime") {
                    Task { await appState.refreshSelectedRuntimeAndModels() }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(appState.selectedSession?.title ?? "New Session")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .mobileBlobStyle(colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
    }

    private var groupedModels: [MobileModelGroup] {
        Dictionary(grouping: appState.availableModels, by: \.provider)
            .map { provider, models in
                MobileModelGroup(
                    provider: provider,
                    models: models.sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
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
            .scrollContentBackground(.hidden)
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
        HStack(alignment: .bottom, spacing: 10) {
            MobileComposerIconButton(systemName: "plus", isDisabled: true) {}

            TextField("Message pi…", text: $appState.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.vertical, 8)
                .foregroundStyle(MobileTheme.textColor(for: colorScheme))

            MobileComposerIconButton(systemName: "mic.fill") {
                appState.showStatus("Voice recording will use pi-appd transcription next.")
            }

            MobileComposerIconButton(
                systemName: "arrow.up",
                isDisabled: appState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                Task { await appState.sendDraft() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MobileTheme.composerAreaBackgroundColor(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

private struct MobileModelGroup: Identifiable {
    let provider: String
    let models: [PiModelOption]
    var id: String { provider }
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
    @Environment(\.colorScheme) private var colorScheme
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
            .background(bubbleBackground)
            .foregroundStyle(bubbleTextColor)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return MobileTheme.accentColor
        case .assistant:
            return MobileTheme.assistantMessageBackgroundColor(for: colorScheme)
        case .system:
            return MobileTheme.assistantMessageBackgroundColor(for: colorScheme).opacity(0.72)
        }
    }

    private var bubbleTextColor: Color {
        message.role == .user ? .black : MobileTheme.textColor(for: colorScheme)
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
    @Environment(\.colorScheme) private var colorScheme
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
                        .fill(MobileTheme.controlTint(for: colorScheme, opacity: 0.06))
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
                        .fill(MobileTheme.controlTint(for: colorScheme, opacity: 0.05))
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

private struct MobileSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MobileTheme.controlTint(for: colorScheme, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MobileIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemName: String
    var help: String = ""
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MobileTheme.accentColor.opacity(isDisabled ? 0.28 : 1))
                .frame(width: 34, height: 34)
                .background(MobileTheme.controlTint(for: colorScheme, opacity: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}

private struct MobileComposerIconButton: View {
    let systemName: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MobileTheme.accentColor.opacity(isDisabled ? 0.28 : 1))
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct MobileBlobModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(MobileTheme.controlTint(for: colorScheme, opacity: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension View {
    func mobileBlobStyle(colorScheme: ColorScheme) -> some View {
        modifier(MobileBlobModifier(colorScheme: colorScheme))
    }

    @ViewBuilder
    func hiddenMobileNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

private enum MobileTheme {
    static let accentColor = Color.yellow

    static func mainBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.055, green: 0.058, blue: 0.065) : Color(red: 0.965, green: 0.965, blue: 0.955)
    }

    static func sidebarBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.078, green: 0.082, blue: 0.092) : Color(red: 0.91, green: 0.91, blue: 0.895)
    }

    static func composerAreaBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.074, green: 0.078, blue: 0.088) : Color(red: 0.93, green: 0.93, blue: 0.92)
    }

    static func textColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    static func assistantMessageBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    static func controlTint(for colorScheme: ColorScheme, opacity: Double) -> Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(opacity)
    }
}
