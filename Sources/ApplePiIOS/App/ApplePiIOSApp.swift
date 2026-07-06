import SwiftUI
import ApplePiCore
import ApplePiRemote

@main
struct ApplePiIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = MobilePiAppState()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(appState)
                .task {
                    await appState.loadInitialCatalogIfConfigured()
                }
                .onChange(of: scenePhase) { _, phase in
                    appState.handleScenePhase(phase)
                }
        }
    }
}

@MainActor
final class MobilePiAppState: ObservableObject {
    @Published var daemonURL: String {
        didSet { saveHost() }
    }
    @Published var daemonToken: String {
        didSet { saveToken() }
    }
    @Published var appearance = MobileAppAppearance() {
        didSet { saveAppearance() }
    }
    @Published private(set) var projects: [PiProject] = []
    @Published private(set) var sessions: [PiSessionSummary] = []
    @Published private(set) var selectedSession: PiSessionSummary?
    @Published private(set) var selectedEvents: [SessionEvent] = []
    @Published private(set) var statusMessage = "Configure pi-appd to begin."
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isLoadingSession = false
    @Published private(set) var isSending = false
    @Published private(set) var selectedRuntime: SessionRuntimeState?
    @Published private(set) var availableModels: [PiModelOption] = []
    @Published private(set) var cachedAvailableModels: [PiModelOption] = []
    @Published private(set) var isLoadingRuntime = false
    @Published private(set) var isLoadingAvailableModels = false
    @Published private(set) var defaultModelPreference: DefaultModelPreference?
    @Published var draft = ""
    @Published var sessionSearchText = ""

    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]
    private static let maxSelectedEventsRetained = 260
    private static let maxStoredTextCharacters = 50_000

    private let defaults: UserDefaults
    private let hostDefaultsKey = "ApplePiIOS.host"
    private let appearanceDefaultsKey = "ApplePi.appearance"
    private let modelDefaultsKey = "ApplePi.modelDefaults"
    private let availableModelsCacheDefaultsKey = "ApplePi.availableModelsCache"
    private var availableModelsCacheLoadedAt: Date?
    private var catalogStreamTask: Task<Void, Never>?
    private var selectedSessionStreamTask: Task<Void, Never>?
    private var selectedSessionGeneration = UUID()
    private var selectedPersistedEventIDs = Set<String>()
    private var selectedLastLine: Int?
    private var isAppActive = true
    private var isChatVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: hostDefaultsKey),
           let host = try? JSONDecoder().decode(PiHostConfiguration.self, from: data) {
            daemonURL = host.remoteDaemonURL
            daemonToken = RemoteDaemonTokenStore.readToken(for: host) ?? ""
        } else {
            daemonURL = ""
            daemonToken = ""
        }
        loadAppearance()
        loadModelDefaults()
        loadAvailableModelsCache()
    }

    deinit {
        catalogStreamTask?.cancel()
        selectedSessionStreamTask?.cancel()
    }

    var host: PiHostConfiguration {
        PiHostConfiguration(remoteDaemonURL: daemonURL)
    }

    var isConfigured: Bool {
        host.hasRemoteDaemonConfigured
    }

    var filteredVisibleEvents: [SessionEvent] {
        selectedEvents.filter(\.isVisibleInTranscript)
    }

    var filteredSessions: [PiSessionSummary] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query)
                || session.subtitle.localizedCaseInsensitiveContains(query)
                || (session.latestModel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var selectedModelDisplayName: String {
        selectedRuntime?.modelDisplayName ?? selectedSession?.latestModel ?? "model"
    }

    var selectedModelID: String? {
        guard let provider = selectedRuntime?.provider?.nilIfBlank,
              let modelID = selectedRuntime?.modelID?.nilIfBlank else { return nil }
        return "\(provider)/\(modelID)"
    }

    var selectedThinkingLevel: String {
        selectedRuntime?.thinkingLevel ?? "off"
    }

    var selectableAvailableModels: [PiModelOption] {
        let currentSessionModels = Self.selectableModels(from: availableModels)
        return currentSessionModels.isEmpty ? cachedSelectableAvailableModels : currentSessionModels
    }

    var cachedSelectableAvailableModels: [PiModelOption] {
        Self.selectableModels(from: cachedAvailableModels)
    }

    var defaultModelDisplayName: String {
        guard let defaultModelPreference else { return "Use daemon default" }
        return defaultModelPreference.id
    }

    var defaultThinkingDisplayName: String {
        defaultModelPreference?.thinkingLevel?.nilIfBlank ?? "Use daemon default"
    }

    func loadInitialCatalogIfConfigured() async {
        guard isConfigured else { return }
        isAppActive = true
        await reloadCatalog()
        startCatalogStream()
        if isChatVisible {
            await catchUpSelectedSession(reason: "initial load")
            startSelectedSessionStreamIfPossible()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppActive = true
            guard isConfigured else { return }
            startCatalogStream()
            Task {
                await reloadCatalog(quietly: true)
                if self.isChatVisible {
                    await self.catchUpSelectedSession(reason: "foreground")
                    self.startSelectedSessionStreamIfPossible()
                }
            }
        case .background, .inactive:
            isAppActive = false
            stopSelectedSessionStream()
            stopCatalogStream()
        @unknown default:
            break
        }
    }

    func setChatVisible(_ visible: Bool) {
        isChatVisible = visible
        if visible {
            Task {
                await catchUpSelectedSession(reason: "chat visible")
                startSelectedSessionStreamIfPossible()
            }
        } else {
            stopSelectedSessionStream()
        }
    }

    func showStatus(_ message: String) {
        statusMessage = message
    }

    func testConnection() async {
        guard isConfigured else {
            statusMessage = "Remote API URL is not configured."
            return
        }
        do {
            statusMessage = try await RemoteDaemonClient().testConnection(host: host, tokenOverride: daemonToken.nilIfBlank)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadCatalog(quietly: Bool = false) async {
        guard isConfigured else {
            statusMessage = "Remote API URL is not configured."
            return
        }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let snapshot = try await RemoteDaemonClient().loadCatalog(
                host: host,
                activeProjectDirectory: nil,
                tokenOverride: daemonToken.nilIfBlank
            )
            applyCatalog(snapshot)
            if !quietly {
                statusMessage = "Loaded \(snapshot.projects.count) projects, \(snapshot.sessions.count) sessions."
            }
        } catch {
            if !quietly {
                statusMessage = error.localizedDescription
            }
        }
    }

    func startCatalogStream() {
        catalogStreamTask?.cancel()
        guard isAppActive, isConfigured else { return }
        let host = host
        let token = daemonToken.nilIfBlank
        let client = RemoteDaemonClient()
        catalogStreamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await event in client.streamCatalogSnapshots(host: host, tokenOverride: token) {
                        guard !Task.isCancelled else { return }
                        self?.handleCatalogStreamEvent(event)
                    }
                    return
                } catch {
                    await MainActor.run {
                        self?.statusMessage = "Catalog stream disconnected: \(error.localizedDescription)"
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func stopCatalogStream() {
        catalogStreamTask?.cancel()
        catalogStreamTask = nil
    }

    func selectSession(_ session: PiSessionSummary) async {
        selectedSession = session
        selectedRuntime = nil
        resetSelectedTranscript()
        await reloadSelectedSession()
        await refreshSelectedRuntimeAndModels()
    }

    func startNewSession() {
        selectedSession = nil
        selectedRuntime = nil
        resetSelectedTranscript()
        stopSelectedSessionStream()
        statusMessage = "New session ready."
    }

    func reloadSelectedSession() async {
        guard let selectedSession else { return }
        let generation = UUID()
        selectedSessionGeneration = generation
        stopSelectedSessionStream()
        isLoadingSession = true
        defer { isLoadingSession = false }
        do {
            let page = try await RemoteDaemonClient().loadSessionEventPage(
                host: host,
                sessionID: selectedSession.id,
                limit: 120,
                tokenOverride: daemonToken.nilIfBlank
            )
            guard self.selectedSession?.id == selectedSession.id,
                  selectedSessionGeneration == generation else { return }
            replaceSelectedTranscript(with: page)
            statusMessage = "Loaded session \(selectedSession.title)."
            startSelectedSessionStreamIfPossible()
            Task { await refreshSelectedRuntimeAndModels() }
        } catch {
            guard self.selectedSession?.id == selectedSession.id else { return }
            statusMessage = error.localizedDescription
            startSelectedSessionStreamIfPossible()
        }
    }

    func refreshSelectedRuntimeAndModels() async {
        guard let sessionID = selectedSession?.id.nilIfBlank else {
            selectedRuntime = nil
            availableModels = []
            return
        }
        isLoadingRuntime = true
        defer { isLoadingRuntime = false }
        do {
            async let runtime = RemoteDaemonClient().loadSessionRuntime(
                host: host,
                sessionID: sessionID,
                tokenOverride: daemonToken.nilIfBlank
            )
            async let models = RemoteDaemonClient().loadAvailableModels(
                host: host,
                sessionID: sessionID,
                tokenOverride: daemonToken.nilIfBlank
            )
            let (loadedRuntime, loadedModels) = try await (runtime, models)
            guard selectedSession?.id == sessionID else { return }
            selectedRuntime = loadedRuntime
            availableModels = Self.selectableModels(from: loadedModels)
            if !loadedModels.isEmpty {
                cacheAvailableModels(Self.selectableModels(from: loadedModels))
            }
        } catch {
            guard selectedSession?.id == sessionID else { return }
            statusMessage = "Could not load runtime: \(error.localizedDescription)"
        }
    }

    func setSelectedModel(_ model: PiModelOption) async {
        guard let sessionID = selectedSession?.id.nilIfBlank else { return }
        do {
            let runtime = try await RemoteDaemonClient().setSessionModel(
                host: host,
                sessionID: sessionID,
                provider: model.provider,
                modelID: model.modelID,
                tokenOverride: daemonToken.nilIfBlank
            )
            guard selectedSession?.id == sessionID else { return }
            selectedRuntime = runtime
            await reloadCatalog(quietly: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setSelectedThinkingLevel(_ level: String) async {
        guard let sessionID = selectedSession?.id.nilIfBlank else { return }
        do {
            let runtime = try await RemoteDaemonClient().setSessionThinkingLevel(
                host: host,
                sessionID: sessionID,
                level: level,
                tokenOverride: daemonToken.nilIfBlank
            )
            guard selectedSession?.id == sessionID else { return }
            selectedRuntime = runtime
            await reloadCatalog(quietly: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameSelectedSession(to proposedTitle: String) {
        guard let session = selectedSession else { return }
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.title else { return }

        let previous = session
        upsertSession(renamedSummary(previous, title: title))
        statusMessage = "Renamed \(previous.title)"

        let host = host
        let token = daemonToken.nilIfBlank
        Task { [weak self] in
            do {
                let updated = try await RemoteDaemonClient().renameSession(
                    host: host,
                    sessionID: previous.id,
                    name: title,
                    tokenOverride: token
                )
                await MainActor.run {
                    guard let self, self.host == host else { return }
                    self.upsertSession(updated)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.host == host else { return }
                    self.upsertSession(previous)
                    self.statusMessage = "Could not rename \(previous.title): \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshAvailableModelsCache(force: Bool = false) {
        guard isConfigured else {
            statusMessage = "Remote API URL is not configured."
            return
        }
        if !force, !cachedSelectableAvailableModels.isEmpty { return }
        if isLoadingAvailableModels { return }

        isLoadingAvailableModels = true
        let host = host
        let token = daemonToken.nilIfBlank
        Task { [weak self] in
            do {
                let models = try await RemoteDaemonClient().loadAvailableModels(host: host, tokenOverride: token)
                await MainActor.run {
                    guard let self, self.host == host else { return }
                    self.cacheAvailableModels(Self.selectableModels(from: models))
                    self.isLoadingAvailableModels = false
                    if self.selectedSession != nil {
                        self.availableModels = Self.selectableModels(from: models)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingAvailableModels = false
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func setDefaultModel(_ model: PiModelOption?) {
        guard let model else {
            setDefaultModelPreference(nil)
            return
        }
        setDefaultModelPreference(DefaultModelPreference(
            provider: model.provider,
            modelID: model.modelID,
            thinkingLevel: defaultModelPreference?.thinkingLevel
        ))
    }

    func setDefaultThinkingLevel(_ level: String?) {
        guard var preference = defaultModelPreference else { return }
        preference.thinkingLevel = level?.nilIfBlank
        setDefaultModelPreference(preference)
    }

    func setDefaultModelPreference(_ preference: DefaultModelPreference?) {
        defaultModelPreference = preference
        saveModelDefaults()
    }

    func updateAppearance(_ update: (inout MobileAppAppearance) -> Void) {
        var copy = appearance
        update(&copy)
        appearance = copy
    }

    func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let startsNewSession = selectedSession == nil
        draft = ""
        if startsNewSession {
            resetSelectedTranscript()
        }
        appendOptimisticUserMessage(prompt)
        isSending = true
        defer { isSending = false }

        let host = host
        do {
            if let selectedSession {
                try await RemoteDaemonClient().streamSend(host: host, sessionID: selectedSession.id, prompt: prompt) { event in
                    await self.handleTurnStreamEvent(event)
                }
            } else {
                var request = PiLaunchRequest(workingDirectory: host.defaultWorkingDirectory)
                if let defaultModelPreference {
                    request.initialModelProvider = defaultModelPreference.provider
                    request.initialModelID = defaultModelPreference.modelID
                    request.initialThinkingLevel = defaultModelPreference.thinkingLevel
                    request.hasExplicitInitialModel = true
                    request.hasExplicitInitialThinkingLevel = defaultModelPreference.thinkingLevel?.nilIfBlank != nil
                }
                try await RemoteDaemonClient().streamNewSession(host: host, request: request, prompt: prompt) { event in
                    await self.handleTurnStreamEvent(event)
                }
            }
            await catchUpSelectedSession(reason: "send complete")
            await reloadCatalog(quietly: true)
            startSelectedSessionStreamIfPossible()
        } catch {
            statusMessage = error.localizedDescription
            await catchUpSelectedSession(reason: "send error")
            startSelectedSessionStreamIfPossible()
        }
    }

    private func handleCatalogStreamEvent(_ event: CatalogStreamEvent) {
        switch event {
        case .snapshot(let snapshot):
            applyCatalog(snapshot)
        case .sessionUpdated(let session):
            upsertSession(session)
        case .sessionRemoved(let sessionId):
            removeSession(id: sessionId)
        case .runtimeChanged(let sessionId, let runtime):
            if selectedSession?.id == sessionId {
                selectedRuntime = runtime
            }
        case .unknown:
            break
        }
    }

    private func handleTurnStreamEvent(_ event: PiTurnStreamEvent) async {
        await MainActor.run {
            switch event {
            case .sessionBound(let binding):
                bindSelectedSession(binding)
                statusMessage = "Session: \(binding.title)"
                startSelectedSessionStreamIfPossible()
                Task { await refreshSelectedRuntimeAndModels() }
            case .sessionHeader(let meta):
                if selectedSession == nil {
                    bindSelectedSession(
                        PiSessionBinding(
                            sessionID: meta.id,
                            sessionPath: nil,
                            title: meta.displayName ?? "Pi",
                            workingDirectory: meta.workingDirectory
                        )
                    )
                }
            case .sessionEvents(let events, _):
                mergeTransientEvents(events)
            case .turnEnd:
                statusMessage = "Turn finished."
            case .agentEnd, .outputComplete:
                statusMessage = "Done."
            case .abort:
                statusMessage = "Aborted."
            case .streamError(let message):
                statusMessage = message
            }
        }
    }

    private func bindSelectedSession(_ binding: PiSessionBinding) {
        guard let id = binding.sessionID?.nilIfBlank ?? binding.sessionPath?.nilIfBlank else { return }
        let summary = PiSessionSummary(
            id: id,
            filePath: binding.sessionPath ?? id,
            projectID: binding.workingDirectory ?? "remote",
            title: binding.title,
            workingDirectory: binding.workingDirectory,
            messageCount: max(selectedEvents.filter(\.isVisibleInTranscript).count, 0),
            modifiedAt: Date(),
            displayName: binding.title,
            parentSession: nil,
            branchCount: 0,
            labelCount: 0,
            branchSummaryCount: 0,
            latestModel: nil,
            isGenerating: true
        )
        selectedSession = summary
        upsertSession(summary)
    }

    private func renamedSummary(_ session: PiSessionSummary, title: String) -> PiSessionSummary {
        PiSessionSummary(
            id: session.id,
            filePath: session.filePath,
            projectID: session.projectID,
            title: title,
            workingDirectory: session.workingDirectory,
            messageCount: session.messageCount,
            modifiedAt: Date(),
            displayName: title,
            parentSession: session.parentSession,
            branchCount: session.branchCount,
            labelCount: session.labelCount,
            branchSummaryCount: session.branchSummaryCount,
            latestModel: session.latestModel,
            isGenerating: session.isGenerating
        )
    }

    private func applyCatalog(_ snapshot: PiCatalogSnapshot) {
        projects = snapshot.projects.sorted { lhs, rhs in
            (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
        }
        sessions = snapshot.sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        if let selectedSession,
           let updated = sessions.first(where: { $0.id == selectedSession.id }) {
            self.selectedSession = updated
        }
    }

    private func upsertSession(_ session: PiSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.modifiedAt > $1.modifiedAt }
        if selectedSession?.id == session.id {
            selectedSession = session
        }
    }

    private func removeSession(id: String) {
        sessions.removeAll { $0.id == id }
        if selectedSession?.id == id {
            selectedSession = nil
            resetSelectedTranscript()
            stopSelectedSessionStream()
        }
    }

    private func catchUpSelectedSession(reason: String) async {
        guard isAppActive,
              isChatVisible,
              isConfigured,
              let sessionID = selectedSession?.id.nilIfBlank else { return }
        let after = selectedLastLine ?? -1
        do {
            let page = try await RemoteDaemonClient().loadSessionEventPage(
                host: host,
                sessionID: sessionID,
                limit: nil,
                after: after,
                tokenOverride: daemonToken.nilIfBlank
            )
            guard selectedSession?.id == sessionID else { return }
            mergePersistedPage(page)
            if !page.events.isEmpty {
                statusMessage = "Synced \(page.events.count) event(s)."
            }
        } catch {
            guard selectedSession?.id == sessionID else { return }
            statusMessage = "Could not sync session: \(error.localizedDescription)"
        }
    }

    private func startSelectedSessionStreamIfPossible() {
        guard isAppActive,
              isChatVisible,
              isConfigured,
              selectedSessionStreamTask == nil,
              let sessionID = selectedSession?.id.nilIfBlank else { return }
        let host = host
        let token = daemonToken.nilIfBlank
        let client = RemoteDaemonClient()
        let startAfter = selectedLastLine ?? -1
        selectedSessionStreamTask = Task { [weak self] in
            var after = startAfter
            while !Task.isCancelled {
                do {
                    for try await page in client.streamSessionEventPages(host: host, sessionID: sessionID, after: after, tokenOverride: token) {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let self, self.selectedSession?.id == sessionID else { return }
                            self.mergePersistedPage(page)
                            after = self.selectedLastLine ?? after
                        }
                    }
                    return
                } catch {
                    await MainActor.run {
                        guard let self, self.selectedSession?.id == sessionID else { return }
                        self.statusMessage = "Session stream disconnected: \(error.localizedDescription)"
                        after = self.selectedLastLine ?? after
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func stopSelectedSessionStream() {
        selectedSessionStreamTask?.cancel()
        selectedSessionStreamTask = nil
    }

    private func resetSelectedTranscript() {
        selectedEvents = []
        selectedPersistedEventIDs = []
        selectedLastLine = nil
        selectedSessionGeneration = UUID()
    }

    private func replaceSelectedTranscript(with page: SessionEventsPage) {
        selectedEvents = page.events.map(compactEventForMobileMemory)
        selectedPersistedEventIDs = Set(selectedEvents.map(\.id))
        selectedLastLine = page.lastLine ?? page.events.map(\.lineIndex).max()
        sortSelectedEventsForDisplay()
    }

    private func mergePersistedPage(_ page: SessionEventsPage) {
        guard !page.events.isEmpty || page.lastLine != nil else { return }
        for rawEvent in page.events {
            let event = compactEventForMobileMemory(rawEvent)
            selectedPersistedEventIDs.insert(event.id)
            removeTransientEvents(matchingPersisted: event)
            upsertSelectedEvent(event, allowPersistedToWin: true)
        }
        if let lastLine = page.lastLine {
            selectedLastLine = max(selectedLastLine ?? lastLine, lastLine)
        } else if let eventLastLine = page.events.map(\.lineIndex).max() {
            selectedLastLine = max(selectedLastLine ?? eventLastLine, eventLastLine)
        }
        sortSelectedEventsForDisplay()
    }

    private func mergeTransientEvents(_ events: [SessionEvent]) {
        guard !events.isEmpty else { return }
        for rawEvent in events {
            let event = compactEventForMobileMemory(rawEvent)
            guard !selectedPersistedEventIDs.contains(event.id) else { continue }
            removeTransientEvents(matchingPersisted: event)
            upsertSelectedEvent(event, allowPersistedToWin: false)
        }
        sortSelectedEventsForDisplay()
    }

    private func appendOptimisticUserMessage(_ prompt: String) {
        let message = Message(
            id: "optimistic-user-\(UUID().uuidString)",
            role: .user,
            content: [.text(prompt)],
            model: nil,
            timestamp: Date(),
            parentId: nil
        )
        upsertSelectedEvent(compactEventForMobileMemory(.message(message, lineIndex: Int.max)), allowPersistedToWin: false)
        sortSelectedEventsForDisplay()
    }

    private func compactEventForMobileMemory(_ event: SessionEvent) -> SessionEvent {
        switch event {
        case .message(let message, let lineIndex):
            let compactedContent = message.content.map { block -> ContentBlock in
                switch block {
                case .text(let text):
                    return .text(truncatedForMobileMemory(text, label: "message"))
                case .thinking(let text, let signature):
                    return .thinking(truncatedForMobileMemory(text, label: "thinking"), signature: signature)
                case .image:
                    return block
                }
            }
            return .message(
                Message(
                    id: message.id,
                    role: message.role,
                    content: compactedContent,
                    model: message.model,
                    timestamp: message.timestamp,
                    parentId: message.parentId
                ),
                lineIndex: lineIndex
            )
        case .toolCall(let call, let lineIndex):
            return .toolCall(
                .function(
                    id: call.id,
                    name: call.name,
                    arguments: truncatedForMobileMemory(call.arguments, label: "tool call")
                ),
                lineIndex: lineIndex
            )
        case .toolResult(let result, let lineIndex):
            return .toolResult(
                .result(
                    id: result.id,
                    callId: result.callId,
                    toolName: result.toolName,
                    output: truncatedForMobileMemory(result.output, label: "tool result"),
                    isError: result.isError
                ),
                lineIndex: lineIndex
            )
        case .meta, .other:
            return event
        }
    }

    private func truncatedForMobileMemory(_ text: String, label: String) -> String {
        guard text.count > Self.maxStoredTextCharacters else { return text }
        let prefix = String(text.prefix(Self.maxStoredTextCharacters))
        return "\(prefix)\n\n… \(label) truncated on iPhone to reduce memory (\(text.count) characters total). Open the session on Mac for the full content."
    }

    private func upsertSelectedEvent(_ event: SessionEvent, allowPersistedToWin: Bool) {
        if let index = selectedEvents.firstIndex(where: { $0.id == event.id }) {
            if allowPersistedToWin || !selectedPersistedEventIDs.contains(event.id) {
                selectedEvents[index] = event
            }
        } else {
            selectedEvents.append(event)
        }
    }

    private func removeTransientEvents(matchingPersisted persistedEvent: SessionEvent) {
        selectedEvents.removeAll { existing in
            !selectedPersistedEventIDs.contains(existing.id)
                && transientEvent(existing, matchesPersistedReplacement: persistedEvent)
        }
    }

    private func transientEvent(_ transient: SessionEvent, matchesPersistedReplacement persisted: SessionEvent) -> Bool {
        switch (transient, persisted) {
        case (.message(let transientMessage, _), .message(let persistedMessage, _)):
            guard transientMessage.role == persistedMessage.role else { return false }
            if transientMessage.id == persistedMessage.id { return true }
            let transientSignature = messageSignature(for: transientMessage)
            let persistedSignature = messageSignature(for: persistedMessage)
            if !transientSignature.isEmpty, transientSignature == persistedSignature {
                return true
            }
            return transientMessage.content == persistedMessage.content
        case (.toolCall(let transientCall, _), .toolCall(let persistedCall, _)):
            return transientCall.id == persistedCall.id
        case (.toolResult(let transientResult, _), .toolResult(let persistedResult, _)):
            return transientResult.id == persistedResult.id
                || (!transientResult.callId.isEmpty && transientResult.callId == persistedResult.callId)
        default:
            return false
        }
    }

    private func messageSignature(for message: Message) -> String {
        var parts: [String] = []
        var imageCount = 0
        for block in message.content {
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            case .thinking(let text, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append("[thinking]\(trimmed)") }
            case .image:
                imageCount += 1
            }
        }
        if imageCount > 0 {
            parts.append("[images:\(imageCount)]")
        }
        return parts.joined(separator: "\n")
    }

    private func sortSelectedEventsForDisplay() {
        let persistedIDs = selectedPersistedEventIDs
        selectedEvents = selectedEvents.enumerated().sorted { lhs, rhs in
            let lhsPersisted = persistedIDs.contains(lhs.element.id)
            let rhsPersisted = persistedIDs.contains(rhs.element.id)
            switch (lhsPersisted, rhsPersisted) {
            case (true, true):
                if lhs.element.lineIndex != rhs.element.lineIndex {
                    return lhs.element.lineIndex < rhs.element.lineIndex
                }
                return lhs.offset < rhs.offset
            case (true, false):
                return true
            case (false, true):
                return false
            case (false, false):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
        trimSelectedEventsForMobileMemoryIfNeeded()
    }

    private func trimSelectedEventsForMobileMemoryIfNeeded() {
        guard selectedEvents.count > Self.maxSelectedEventsRetained else { return }
        selectedEvents = Array(selectedEvents.suffix(Self.maxSelectedEventsRetained))
        selectedPersistedEventIDs = selectedPersistedEventIDs.intersection(Set(selectedEvents.map(\.id)))
    }

    private static func selectableModels(from models: [PiModelOption]) -> [PiModelOption] {
        models
            .filter { model in
                let provider = model.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return provider != "groq" && provider != "groq-api" && !model.id.lowercased().hasPrefix("groq/")
            }
            .sorted {
                if $0.provider.localizedCaseInsensitiveCompare($1.provider) != .orderedSame {
                    return $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending
                }
                return $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending
            }
    }

    private func loadAppearance() {
        guard let data = defaults.data(forKey: appearanceDefaultsKey),
              let decoded = try? JSONDecoder().decode(MobileAppAppearance.self, from: data) else {
            return
        }
        appearance = decoded
    }

    private func saveAppearance() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: appearanceDefaultsKey)
    }

    private func loadModelDefaults() {
        guard let data = defaults.data(forKey: modelDefaultsKey),
              let decoded = try? JSONDecoder().decode(DefaultModelPreference.self, from: data),
              Self.selectableModels(from: [PiModelOption(
                provider: decoded.provider,
                modelID: decoded.modelID,
                name: nil,
                reasoning: false,
                contextWindow: nil
              )]).isEmpty == false else {
            return
        }
        defaultModelPreference = decoded
    }

    private func saveModelDefaults() {
        guard let defaultModelPreference else {
            defaults.removeObject(forKey: modelDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(defaultModelPreference) else { return }
        defaults.set(data, forKey: modelDefaultsKey)
    }

    private struct AvailableModelsCacheSnapshot: Codable {
        let models: [PiModelOption]
        let loadedAt: Date
    }

    private func loadAvailableModelsCache() {
        guard let data = defaults.data(forKey: availableModelsCacheDefaultsKey),
              let decoded = try? JSONDecoder().decode(AvailableModelsCacheSnapshot.self, from: data) else {
            return
        }
        cachedAvailableModels = Self.selectableModels(from: decoded.models)
        availableModelsCacheLoadedAt = decoded.loadedAt
    }

    private func cacheAvailableModels(_ models: [PiModelOption], loadedAt: Date = Date()) {
        cachedAvailableModels = Self.selectableModels(from: models)
        availableModelsCacheLoadedAt = loadedAt
        saveAvailableModelsCache()
    }

    private func saveAvailableModelsCache() {
        guard !cachedAvailableModels.isEmpty,
              let loadedAt = availableModelsCacheLoadedAt,
              let data = try? JSONEncoder().encode(AvailableModelsCacheSnapshot(models: cachedAvailableModels, loadedAt: loadedAt)) else {
            defaults.removeObject(forKey: availableModelsCacheDefaultsKey)
            return
        }
        defaults.set(data, forKey: availableModelsCacheDefaultsKey)
    }

    private func saveHost() {
        let host = host
        if let data = try? JSONEncoder().encode(host) {
            defaults.set(data, forKey: hostDefaultsKey)
        }
    }

    private func saveToken() {
        let token = daemonToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if token.isEmpty {
                try RemoteDaemonTokenStore.deleteToken(for: host)
            } else {
                try RemoteDaemonTokenStore.saveToken(token, for: host)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
