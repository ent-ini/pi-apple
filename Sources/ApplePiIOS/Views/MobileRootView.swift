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
        .tint(appState.appearance.accentColor)
        .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
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
                .background(appState.appearance.topBarBackgroundColor(for: resolvedColorScheme))

            Divider().opacity(0.24)

            content
        }
        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
        .background(appState.appearance.sidebarBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
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
    @EnvironmentObject private var appState: MobilePiAppState
    let session: PiSessionSummary
    let isSelected: Bool
    let isSending: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
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
                        .tint(appState.appearance.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()
                .padding(.leading, 12)
                .opacity(isSelected ? 0 : 0.28)
        }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSessionDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var showsModelPicker = false
    @State private var showsThinkingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            chatTopBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(appState.appearance.topBarBackgroundColor(for: resolvedColorScheme))

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
        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
        .hiddenMobileNavigationBar()
        .task(id: appState.selectedSession?.id) {
            await appState.refreshSelectedRuntimeAndModels()
        }
        .sheet(isPresented: $showsModelPicker) {
            NavigationStack {
                MobileModelPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsThinkingPicker) {
            NavigationStack {
                MobileThinkingPickerSheet()
            }
            .environmentObject(appState)
        }
    }

    private var chatTopBar: some View {
        HStack(spacing: 8) {
            MobileIconButton(systemName: "chevron.left", help: "Back") {
                dismiss()
            }

            sessionTitlePill

            if appState.selectedSession != nil {
                MobileRuntimePill(systemName: "cpu", title: appState.selectedModelDisplayName) {
                    showsModelPicker = true
                    appState.refreshAvailableModelsCache()
                }
                MobileRuntimePill(systemName: "brain", title: appState.selectedThinkingLevel) {
                    showsThinkingPicker = true
                }
            }

            Spacer(minLength: 0)

            if appState.isLoadingSession || appState.isLoadingRuntime {
                ProgressView()
                    .controlSize(.small)
                    .tint(appState.appearance.accentColor)
            }

            MobileIconButton(systemName: "square.and.pencil", help: "New session") {
                appState.startNewSession()
            }

            MobileIconButton(systemName: "arrow.clockwise", help: "Reload session", isDisabled: appState.selectedSession == nil || appState.isLoadingSession) {
                Task { await appState.reloadSelectedSession() }
            }
        }
    }

    private var sessionTitlePill: some View {
        Text(appState.selectedSession?.title ?? "New Session")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .mobileBlobStyle(colorScheme: resolvedColorScheme)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
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
                .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))

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
                .fill(appState.appearance.composerAreaBackgroundColor(for: resolvedColorScheme))
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
    @EnvironmentObject private var appState: MobilePiAppState
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
                    MobileMarkdownText(trimmed)
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
            return appState.appearance.userMessageBackgroundColor
        case .assistant:
            return appState.appearance.assistantMessageBackgroundColor(for: resolvedColorScheme)
        case .system:
            return appState.appearance.systemMessageBackgroundColor(for: resolvedColorScheme)
        }
    }

    private var bubbleTextColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.userMessageTextColor
        case .assistant, .system:
            return appState.appearance.assistantMessageTextColor(for: resolvedColorScheme)
        }
    }

    private var visibleBlocks: [ContentBlock] {
        message.content.compactMap { block in
            switch block {
            case .thinking:
                return nil
            case .text(let rawText):
                let visible = MobileMessageTextSanitizer.visibleText(from: rawText)
                return visible.isEmpty ? nil : .text(visible)
            case .image:
                return block
            }
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

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private enum MobileMessageTextSanitizer {
    static func visibleText(from text: String) -> String {
        let withoutSource = text.replacingOccurrences(
            of: #"(?:^|\s)\[source:[^\]]+\]\s*"#,
            with: "\n",
            options: .regularExpression
        )
        let withoutTelegramTopic = withoutSource.replacingOccurrences(
            of: #"(?:^|\n)\[telegram_topic\][\s\S]*?\[/telegram_topic\]\n?"#,
            with: "\n",
            options: .regularExpression
        )
        let collapsed = withoutTelegramTopic.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @EnvironmentObject private var appState: MobilePiAppState
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
                        .fill(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.06))
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
                        .fill(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.05))
                )
        }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var showsDefaultModelPicker = false
    @State private var showsDefaultThinkingPicker = false

    var body: some View {
        Form {
            appearanceSection
            piDefaultsSection
            remoteAPISection
            Section("Status") {
                Text(appState.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
        .sheet(isPresented: $showsDefaultModelPicker) {
            NavigationStack {
                MobileDefaultModelPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsDefaultThinkingPicker) {
            NavigationStack {
                MobileDefaultThinkingPickerSheet()
            }
            .environmentObject(appState)
        }
        .onAppear {
            appState.refreshAvailableModelsCache()
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Mode", selection: Binding(
                get: { appState.appearance.colorScheme },
                set: { newValue in appState.updateAppearance { $0.colorScheme = newValue } }
            )) {
                ForEach(MobileAppColorSchemePreference.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .pickerStyle(.segmented)

            ColorPicker("Accent", selection: Binding(
                get: { appState.appearance.accentColor },
                set: { newValue in appState.updateAppearance { $0.setAccentColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Main background", selection: Binding(
                get: { appState.appearance.mainBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setMainBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Top bar", selection: Binding(
                get: { appState.appearance.topBarBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setTopBarBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Sidebars background", selection: Binding(
                get: { appState.appearance.sidebarBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setSidebarBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Composer area", selection: Binding(
                get: { appState.appearance.composerAreaBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setComposerAreaBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Text", selection: Binding(
                get: { appState.appearance.textColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setTextColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("User message", selection: Binding(
                get: { appState.appearance.userMessageBackgroundColor },
                set: { newValue in appState.updateAppearance { $0.setUserMessageBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("User message text", selection: Binding(
                get: { appState.appearance.userMessageTextColor },
                set: { newValue in appState.updateAppearance { $0.setUserMessageTextColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Assistant message", selection: Binding(
                get: { appState.appearance.assistantMessageBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setAssistantMessageBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Assistant message text", selection: Binding(
                get: { appState.appearance.assistantMessageTextColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setAssistantMessageTextColor(newValue) } }
            ), supportsOpacity: false)

            Button("Reset custom colors") {
                appState.updateAppearance { $0.resetCustomColors() }
            }

            Toggle("Transparent titlebar", isOn: Binding(
                get: { appState.appearance.useTransparentTitlebar },
                set: { newValue in appState.updateAppearance { $0.useTransparentTitlebar = newValue } }
            ))

            TextField("Empty chat message", text: Binding(
                get: { appState.appearance.emptyChatMessage },
                set: { newValue in appState.updateAppearance { $0.emptyChatMessage = newValue } }
            ))
        }
    }

    private var piDefaultsSection: some View {
        Section("Pi defaults") {
            Button {
                showsDefaultModelPicker = true
                appState.refreshAvailableModelsCache()
            } label: {
                settingsValueRow(title: "Default model", value: appState.defaultModelDisplayName)
            }
            .buttonStyle(.plain)

            Button {
                showsDefaultThinkingPicker = true
            } label: {
                settingsValueRow(title: "Default thinking", value: appState.defaultThinkingDisplayName)
            }
            .buttonStyle(.plain)
            .disabled(appState.defaultModelPreference == nil)

            Button(appState.isLoadingAvailableModels ? "Loading models…" : "Refresh model list") {
                appState.refreshAvailableModelsCache(force: true)
            }
            .disabled(appState.isLoadingAvailableModels)

            Text("New sessions use this model explicitly. Existing sessions keep their current model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var remoteAPISection: some View {
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

            Button("Test Connection") {
                Task { await appState.testConnection() }
            }
            Button("Reload Catalog") {
                Task { await appState.reloadCatalog() }
            }
        }
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileRuntimePill: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileModelList(
            models: appState.selectableAvailableModels,
            selectedID: appState.selectedModelID,
            emptyMessage: appState.isLoadingAvailableModels ? "Loading models…" : "No pi models loaded.",
            includesDaemonDefault: false,
            onSelectDefault: nil,
            onSelectModel: { model in
                Task {
                    await appState.setSelectedModel(model)
                    dismiss()
                }
            }
        )
        .navigationTitle("Model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { appState.refreshAvailableModelsCache() }
    }
}

private struct MobileDefaultModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileModelList(
            models: appState.cachedSelectableAvailableModels,
            selectedID: appState.defaultModelPreference?.id,
            emptyMessage: appState.isLoadingAvailableModels ? "Loading models…" : "No cached models yet. Refresh once to populate the picker.",
            includesDaemonDefault: true,
            onSelectDefault: {
                appState.setDefaultModel(nil)
                dismiss()
            },
            onSelectModel: { model in
                appState.setDefaultModel(model)
                dismiss()
            }
        )
        .navigationTitle("Default model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { appState.refreshAvailableModelsCache() }
    }
}

private struct MobileThinkingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileChoiceList(
            title: "Thinking",
            choices: MobilePiAppState.thinkingLevels,
            selected: appState.selectedThinkingLevel,
            includesDefault: false,
            onSelect: { level in
                Task {
                    await appState.setSelectedThinkingLevel(level)
                    dismiss()
                }
            },
            onSelectDefault: nil
        )
    }
}

private struct MobileDefaultThinkingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileChoiceList(
            title: "Default thinking",
            choices: MobilePiAppState.thinkingLevels,
            selected: appState.defaultModelPreference?.thinkingLevel,
            includesDefault: true,
            onSelect: { level in
                appState.setDefaultThinkingLevel(level)
                dismiss()
            },
            onSelectDefault: {
                appState.setDefaultThinkingLevel(nil)
                dismiss()
            }
        )
    }
}

private struct MobileModelList: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let models: [PiModelOption]
    let selectedID: String?
    let emptyMessage: String
    let includesDaemonDefault: Bool
    let onSelectDefault: (() -> Void)?
    let onSelectModel: (PiModelOption) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if includesDaemonDefault, let onSelectDefault {
                    MobileSelectionRow(
                        title: "Use daemon default",
                        subtitle: nil,
                        isSelected: selectedID == nil,
                        action: onSelectDefault
                    )
                }

                if models.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(groupedModels) { group in
                        Text(group.provider)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        ForEach(group.models) { model in
                            MobileSelectionRow(
                                title: model.shortLabel,
                                subtitle: model.provider,
                                isSelected: selectedID == model.id,
                                action: { onSelectModel(model) }
                            )
                        }
                    }
                }

                Button(appState.isLoadingAvailableModels ? "Loading models…" : "Refresh model list") {
                    appState.refreshAvailableModelsCache(force: true)
                }
                .disabled(appState.isLoadingAvailableModels)
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            .padding()
        }
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
    }

    private var groupedModels: [MobileModelGroup] {
        Dictionary(grouping: models, by: \.provider)
            .map { provider, models in
                MobileModelGroup(
                    provider: provider,
                    models: models.sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileChoiceList: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState
    let title: String
    let choices: [String]
    let selected: String?
    let includesDefault: Bool
    let onSelect: (String) -> Void
    let onSelectDefault: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if includesDefault, let onSelectDefault {
                    MobileSelectionRow(
                        title: "Use daemon default",
                        subtitle: nil,
                        isSelected: selected?.nilIfBlank == nil,
                        action: onSelectDefault
                    )
                }

                ForEach(choices, id: \.self) { choice in
                    MobileSelectionRow(
                        title: choice,
                        subtitle: nil,
                        isSelected: selected == choice,
                        action: { onSelect(choice) }
                    )
                }
            }
            .padding()
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSelectionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(appState.appearance.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: isSelected ? 0.14 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
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
        .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let systemName: String
    var help: String = ""
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(appState.appearance.accentColor.opacity(isDisabled ? 0.28 : 1))
                .frame(width: 34, height: 34)
                .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileComposerIconButton: View {
    @EnvironmentObject private var appState: MobilePiAppState
    let systemName: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(appState.appearance.accentColor.opacity(isDisabled ? 0.28 : 1))
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
