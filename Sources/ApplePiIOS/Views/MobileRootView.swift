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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(appState.filteredVisibleEvents) { event in
                        MobileEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding()
            }
            .overlay {
                if appState.isLoadingSession && appState.selectedEvents.isEmpty {
                    ProgressView("Loading \(session.title)…")
                }
            }
            .onChange(of: appState.filteredVisibleEvents.last?.id) { _, id in
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

private struct MobileEventRow: View {
    let event: SessionEvent

    var body: some View {
        switch event {
        case .message(let message, _):
            MessageBubble(message: message)
        case .toolCall(let call, _):
            ToolBlock(title: "Tool: \(call.name)", bodyText: call.arguments)
        case .toolResult(let result, _):
            ToolBlock(title: result.toolName ?? "Tool result", bodyText: result.output)
        case .other(let type, _):
            ToolBlock(title: type, bodyText: "")
        case .meta:
            EmptyView()
        }
    }
}

private struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                MarkdownMessageText(markdown: message.plainText)
            }
            .padding(12)
            .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if message.role != .user { Spacer(minLength: 32) }
        }
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

private struct ToolBlock: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
