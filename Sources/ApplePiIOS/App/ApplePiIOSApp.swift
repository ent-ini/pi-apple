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
    @Published private(set) var sendingSessionIDs: Set<String> = []
    @Published private(set) var selectedRuntime: SessionRuntimeState?
    @Published private(set) var defaultRuntime: SessionRuntimeState?
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
    private static let catalogStreamCoalesceDelay: Duration = .milliseconds(250)

    private struct TurnStreamContext: Sendable {
        let operationID: UUID
        let initialSessionID: String?
        let startedNewSession: Bool
    }

    private let defaults: UserDefaults
    private let hostDefaultsKey = "ApplePiIOS.host"
    private let appearanceDefaultsKey = "ApplePi.appearance"
    private let modelDefaultsKey = "ApplePi.modelDefaults"
    private let availableModelsCacheDefaultsKey = "ApplePi.availableModelsCache"
    private let sessionDefaultsCacheDefaultsKey = "ApplePi.sessionDefaultsCache"
    private var availableModelsCacheLoadedAt: Date?
    private var sessionDefaultsCacheLoadedAt: Date?
    private var catalogStreamTask: Task<Void, Never>?
    private var catalogStreamCoalesceTask: Task<Void, Never>?
    private var pendingCatalogSessionUpdates: [PiSessionSummary] = []
    private var selectedSessionStreamTask: Task<Void, Never>?
    private var deviceCommandRuntime: MobileDeviceCommandRuntime?
    private var selectedSessionGeneration = UUID()
    private var selectedPersistedEventIDs = Set<String>()
    private var selectedLastLine: Int?
    private var isAppActive = true
    private var isChatVisible = false
    private var isLoadingSessionDefaults = false
    private var activeSendOperations = Set<UUID>()
    private var sendOperationSessionIDs: [UUID: String] = [:]
    private var selectedPendingNewSessionSendID: UUID?

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
        loadSessionDefaultsCache()
    }

    deinit {
        catalogStreamTask?.cancel()
        catalogStreamCoalesceTask?.cancel()
        selectedSessionStreamTask?.cancel()
        deviceCommandRuntime?.stop()
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

    var selectedContextUsageDisplayName: String {
        Self.contextUsageDisplayName(selectedRuntime?.contextUsage)
    }

    var isSelectedSessionBusy: Bool {
        isLoadingSession
            || isLoadingRuntime
            || (selectedSession?.isGenerating == true)
            || (selectedSession.map { isSessionSending($0) } ?? false)
            || (selectedSession == nil && (selectedPendingNewSessionSendID.map { activeSendOperations.contains($0) } ?? false))
    }

    var selectableAvailableModels: [PiModelOption] {
        let currentSessionModels = Self.selectableModels(from: availableModels)
        return currentSessionModels.isEmpty ? cachedSelectableAvailableModels : currentSessionModels
    }

    var cachedSelectableAvailableModels: [PiModelOption] {
        Self.selectableModels(from: cachedAvailableModels)
    }

    var defaultRuntimeForDisplay: SessionRuntimeState? {
        guard let defaultRuntime else { return nil }
        return runtime(defaultRuntime, applying: defaultModelPreference)
    }

    func isSessionSending(_ session: PiSessionSummary) -> Bool {
        sendingSessionIDs.contains(session.id)
    }

    var defaultModelDisplayName: String {
        if let defaultModelPreference {
            return defaultModelPreference.id
        }
        if let runtime = defaultRuntimeForDisplay {
            return Self.modelDisplayName(provider: runtime.provider, modelID: runtime.modelID, fallback: runtime.modelDisplayName)
        }
        return "Use daemon default"
    }

    var defaultThinkingDisplayName: String {
        if let thinking = defaultModelPreference?.thinkingLevel?.nilIfBlank {
            return thinking
        }
        return defaultRuntimeForDisplay?.thinkingLevel.nilIfBlank ?? "Use daemon default"
    }

    var defaultContextWindowDisplayName: String {
        guard let runtime = defaultRuntimeForDisplay else { return "unknown" }
        if let window = runtime.contextUsage?.contextWindow {
            return Self.compactTokenCount(window)
        }
        return Self.contextUsageDisplayName(runtime.contextUsage)
    }

    func loadInitialCatalogIfConfigured() async {
        guard isConfigured else { return }
        isAppActive = true
        await reloadCatalog()
        startCatalogStream()
        startDeviceCommandRuntime()
        await refreshSessionDefaultsCache(quietly: true)
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
            startDeviceCommandRuntime()
            Task {
                await reloadCatalog(quietly: true)
                await refreshSessionDefaultsCache(quietly: true)
                if self.isChatVisible {
                    await self.catchUpSelectedSession(reason: "foreground")
                    self.startSelectedSessionStreamIfPossible()
                }
            }
        case .background, .inactive:
            isAppActive = false
            stopSelectedSessionStream()
            stopCatalogStream()
            stopDeviceCommandRuntime()
        @unknown default:
            break
        }
    }

    func setChatVisible(_ visible: Bool) {
        isChatVisible = visible
        if visible {
            Task {
                if selectedSession == nil {
                    await refreshSessionDefaultsCache(quietly: true)
                }
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
            flushPendingCatalogSessionUpdates()
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
        catalogStreamCoalesceTask?.cancel()
        catalogStreamCoalesceTask = nil
        pendingCatalogSessionUpdates = []
    }

    private func startDeviceCommandRuntime() {
        guard isAppActive, isConfigured else { return }
        if deviceCommandRuntime != nil { return }
        let runtime = MobileDeviceCommandRuntime(host: host, token: daemonToken.nilIfBlank) { [weak self] message in
            self?.statusMessage = message
        }
        deviceCommandRuntime = runtime
        runtime.start()
    }

    private func stopDeviceCommandRuntime() {
        deviceCommandRuntime?.stop()
        deviceCommandRuntime = nil
    }

    func selectSession(_ session: PiSessionSummary) {
        selectedPendingNewSessionSendID = nil
        stopSelectedSessionStream()
        selectedSession = session
        selectedRuntime = nil
        resetSelectedTranscript()
        isLoadingSession = true
        Task {
            await reloadSelectedSession()
            await refreshSelectedRuntimeAndModels()
        }
    }

    func startNewSession() {
        selectedPendingNewSessionSendID = nil
        selectedSession = nil
        selectedRuntime = defaultRuntimeForDisplay
        availableModels = cachedSelectableAvailableModels
        resetSelectedTranscript()
        stopSelectedSessionStream()
        statusMessage = "New session ready."
        Task { await refreshSessionDefaultsCache(quietly: true) }
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
            selectedRuntime = defaultRuntimeForDisplay
            availableModels = cachedSelectableAvailableModels
            await refreshSessionDefaultsCache(quietly: true)
            selectedRuntime = defaultRuntimeForDisplay
            availableModels = cachedSelectableAvailableModels
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
                    } else {
                        self.availableModels = self.cachedSelectableAvailableModels
                        self.selectedRuntime = self.defaultRuntimeForDisplay
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

    func refreshSessionDefaultsCache(force: Bool = false, quietly: Bool = false) async {
        guard isConfigured else {
            if !quietly {
                statusMessage = "Remote API URL is not configured."
            }
            return
        }
        if isLoadingSessionDefaults { return }
        if !force,
           defaultRuntime != nil,
           let loadedAt = sessionDefaultsCacheLoadedAt,
           Date().timeIntervalSince(loadedAt) < 5 * 60 {
            return
        }

        isLoadingSessionDefaults = true
        defer { isLoadingSessionDefaults = false }
        let requestHost = host
        let token = daemonToken.nilIfBlank
        do {
            let snapshot = try await RemoteDaemonClient().loadSessionDefaults(
                host: requestHost,
                workingDirectory: requestHost.defaultWorkingDirectory,
                tokenOverride: token
            )
            guard host == requestHost else { return }
            cacheSessionDefaults(snapshot)
            if selectedSession == nil {
                selectedRuntime = defaultRuntimeForDisplay
                availableModels = cachedSelectableAvailableModels
            }
        } catch {
            guard host == requestHost else { return }
            if !quietly {
                statusMessage = error.localizedDescription
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
        if selectedSession == nil {
            selectedRuntime = defaultRuntimeForDisplay
            availableModels = cachedSelectableAvailableModels
        }
    }

    func updateAppearance(_ update: (inout MobileAppAppearance) -> Void) {
        var copy = appearance
        update(&copy)
        appearance = copy
    }

    func abortSelectedSession() async {
        guard let sessionID = selectedSession?.id.nilIfBlank else {
            statusMessage = "No session selected."
            return
        }
        do {
            try await RemoteDaemonClient().abortSession(host: host, sessionID: sessionID, tokenOverride: daemonToken.nilIfBlank)
            statusMessage = "Abort requested."
            await catchUpSelectedSession(sessionID: sessionID, reason: "abort")
            await reloadCatalog(quietly: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func compactSelectedSession(instructions: String = "") async {
        guard let sessionID = selectedSession?.id.nilIfBlank else {
            statusMessage = "No session selected."
            return
        }
        statusMessage = "Compacting session…"
        do {
            try await RemoteDaemonClient().compactSession(
                host: host,
                sessionID: sessionID,
                instructions: instructions,
                tokenOverride: daemonToken.nilIfBlank
            )
            statusMessage = "Session compacted."
            if selectedSession?.id == sessionID {
                await reloadSelectedSession()
            }
            await refreshSelectedRuntimeAndModels()
            await reloadCatalog(quietly: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func sendDraft(attachments: [ChatAttachment] = []) async -> Bool {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return false }
        let effectivePrompt = prompt.isEmpty ? "Please inspect the attached item(s)." : prompt
        let initialSession = selectedSession
        let initialSessionID = initialSession?.id.nilIfBlank
        let startsNewSession = initialSessionID == nil
        let sessionTitleForSource = initialSession?.title ?? "New Session"
        let taggedPrompt = sourceTaggedAppPrompt(effectivePrompt, sessionTitle: sessionTitleForSource)
        let operationID = beginSendOperation(sessionID: initialSessionID)
        let context = TurnStreamContext(
            operationID: operationID,
            initialSessionID: initialSessionID,
            startedNewSession: startsNewSession
        )
        draft = ""
        if startsNewSession {
            selectedPendingNewSessionSendID = operationID
            selectedRuntime = defaultRuntimeForDisplay
            resetSelectedTranscript()
        }
        appendOptimisticUserMessage(taggedPrompt, attachments: attachments)
        defer { finishSendOperation(operationID) }

        let host = host
        do {
            let uploadedAttachments = try await uploadAttachmentsIfNeeded(attachments)
            if let sessionID = initialSessionID {
                try await RemoteDaemonClient().streamSend(host: host, sessionID: sessionID, prompt: taggedPrompt, attachments: uploadedAttachments, keepRunningOnDisconnect: true) { event in
                    await self.handleTurnStreamEvent(event, context: context)
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
                try await RemoteDaemonClient().streamNewSession(host: host, request: request, prompt: taggedPrompt, attachments: uploadedAttachments, keepRunningOnDisconnect: true) { event in
                    await self.handleTurnStreamEvent(event, context: context)
                }
            }
            await catchUpSendOperation(operationID, fallbackSessionID: initialSessionID, reason: "send complete")
            await reloadCatalog(quietly: true)
            startSelectedSessionStreamIfPossible()
            return true
        } catch {
            statusMessage = error.localizedDescription
            await catchUpSendOperation(operationID, fallbackSessionID: initialSessionID, reason: "send error")
            startSelectedSessionStreamIfPossible()
            return false
        }
    }

    private func beginSendOperation(sessionID: String?) -> UUID {
        let operationID = UUID()
        activeSendOperations.insert(operationID)
        if let sessionID {
            sendOperationSessionIDs[operationID] = sessionID
        }
        recomputeSendingState()
        return operationID
    }

    private func bindSendOperation(_ operationID: UUID, to sessionID: String?) {
        guard activeSendOperations.contains(operationID), let sessionID = sessionID?.nilIfBlank else { return }
        sendOperationSessionIDs[operationID] = sessionID
        recomputeSendingState()
    }

    private func finishSendOperation(_ operationID: UUID) {
        activeSendOperations.remove(operationID)
        sendOperationSessionIDs.removeValue(forKey: operationID)
        if selectedPendingNewSessionSendID == operationID {
            selectedPendingNewSessionSendID = nil
        }
        recomputeSendingState()
    }

    private func recomputeSendingState() {
        isSending = !activeSendOperations.isEmpty
        sendingSessionIDs = Set(sendOperationSessionIDs.values)
    }

    private func catchUpSendOperation(_ operationID: UUID, fallbackSessionID: String?, reason: String) async {
        guard let sessionID = sendOperationSessionIDs[operationID] ?? fallbackSessionID else { return }
        await catchUpSelectedSession(sessionID: sessionID, reason: reason)
    }

    private func handleCatalogStreamEvent(_ event: CatalogStreamEvent) {
        switch event {
        case .snapshot(let snapshot):
            flushPendingCatalogSessionUpdates()
            applyCatalog(snapshot)
        case .sessionUpdated(let session):
            enqueueCatalogSessionUpdate(session)
        case .sessionRemoved(let sessionId):
            flushPendingCatalogSessionUpdates()
            removeSession(id: sessionId)
        case .runtimeChanged(let sessionId, let runtime):
            if selectedSession?.id == sessionId {
                selectedRuntime = runtime
            }
        case .unknown:
            break
        }
    }

    private func enqueueCatalogSessionUpdate(_ session: PiSessionSummary) {
        pendingCatalogSessionUpdates.removeAll { $0.id == session.id }
        pendingCatalogSessionUpdates.append(session)
        guard catalogStreamCoalesceTask == nil else { return }
        catalogStreamCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.catalogStreamCoalesceDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.flushPendingCatalogSessionUpdates()
            }
        }
    }

    private func flushPendingCatalogSessionUpdates() {
        catalogStreamCoalesceTask?.cancel()
        catalogStreamCoalesceTask = nil
        guard !pendingCatalogSessionUpdates.isEmpty else { return }
        let updates = pendingCatalogSessionUpdates
        pendingCatalogSessionUpdates = []
        for session in updates {
            upsertSession(session)
        }
    }

    private func handleTurnStreamEvent(_ event: PiTurnStreamEvent, context: TurnStreamContext) async {
        await MainActor.run {
            switch event {
            case .sessionBound(let binding):
                bindSendOperation(context.operationID, to: binding.sessionID ?? binding.sessionPath)
                guard shouldApplyTurnStreamEvent(context) else { return }
                bindSelectedSession(binding)
                statusMessage = "Session: \(binding.title)"
                startSelectedSessionStreamIfPossible()
                Task { await refreshSelectedRuntimeAndModels() }
            case .sessionHeader(let meta):
                bindSendOperation(context.operationID, to: meta.id)
                guard shouldApplyTurnStreamEvent(context) else { return }
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
                guard shouldApplyTurnStreamEvent(context) else { return }
                mergeTransientEvents(events)
            case .turnEnd:
                guard shouldApplyTurnStreamEvent(context) else { return }
                statusMessage = "Turn finished."
            case .agentEnd, .outputComplete:
                guard shouldApplyTurnStreamEvent(context) else { return }
                statusMessage = "Done."
            case .abort:
                guard shouldApplyTurnStreamEvent(context) else { return }
                statusMessage = "Aborted."
            case .streamError(let message):
                guard shouldApplyTurnStreamEvent(context) else { return }
                statusMessage = message
            }
        }
    }

    private func shouldApplyTurnStreamEvent(_ context: TurnStreamContext) -> Bool {
        if let selectedSessionID = selectedSession?.id.nilIfBlank {
            let operationSessionID = sendOperationSessionIDs[context.operationID] ?? context.initialSessionID
            return operationSessionID == selectedSessionID
        }
        return context.startedNewSession && selectedPendingNewSessionSendID == context.operationID
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
        let sortedProjects = snapshot.projects.sorted { lhs, rhs in
            (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
        }
        let sortedSessions = snapshot.sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        if projects != sortedProjects {
            projects = sortedProjects
        }
        if sessions != sortedSessions {
            sessions = sortedSessions
        }
        if let selectedSession,
           let updated = sortedSessions.first(where: { $0.id == selectedSession.id }),
           self.selectedSession != updated {
            self.selectedSession = updated
        }
    }

    private func upsertSession(_ session: PiSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard sessions[index] != session else { return }
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.modifiedAt > $1.modifiedAt }
        if selectedSession?.id == session.id, selectedSession != session {
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
        guard let sessionID = selectedSession?.id.nilIfBlank else { return }
        await catchUpSelectedSession(sessionID: sessionID, reason: reason)
    }

    private func catchUpSelectedSession(sessionID: String, reason: String) async {
        guard isAppActive,
              isChatVisible,
              isConfigured,
              selectedSession?.id == sessionID else { return }
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

    private func appendOptimisticUserMessage(_ prompt: String, attachments: [ChatAttachment]) {
        var content = attachments.map { Self.optimisticContentBlock(for: $0) }
        content.append(.text(prompt))
        let message = Message(
            id: "optimistic-user-\(UUID().uuidString)",
            role: .user,
            content: content,
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
                    isError: result.isError,
                    detailsJSON: result.detailsJSON
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

    private func uploadAttachmentsIfNeeded(_ attachments: [ChatAttachment]) async throws -> [UploadedAttachmentReference] {
        guard !attachments.isEmpty else { return [] }
        let client = RemoteDaemonClient()
        var uploaded: [UploadedAttachmentReference] = []
        uploaded.reserveCapacity(attachments.count)
        for attachment in attachments {
            uploaded.append(try await client.uploadAttachment(host: host, attachment: attachment))
        }
        return uploaded
    }

    private static func optimisticContentBlock(for attachment: ChatAttachment) -> ContentBlock {
        switch attachment.kind {
        case .image:
            return .image(path: attachment.filePath, mime: attachment.mimeType)
        case .file:
            return .text("<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Binary file attached: \(attachment.displayName.xmlEscapedForPrompt)]</file>")
        case .audio:
            return .text("<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Audio attachment: \(attachment.displayName.xmlEscapedForPrompt)]</file>")
        }
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

    private func runtime(_ runtime: SessionRuntimeState, applying preference: DefaultModelPreference?) -> SessionRuntimeState {
        let provider = preference?.provider.nilIfBlank ?? runtime.provider
        let modelID = preference?.modelID.nilIfBlank ?? runtime.modelID
        let thinkingLevel = preference?.thinkingLevel?.nilIfBlank ?? runtime.thinkingLevel
        let matchingModel = cachedSelectableAvailableModels.first { model in
            model.provider == provider && model.modelID == modelID
        }
        return SessionRuntimeState(
            sessionID: runtime.sessionID,
            sessionPath: runtime.sessionPath,
            provider: provider,
            modelID: modelID,
            modelName: matchingModel?.name ?? runtime.modelName,
            thinkingLevel: thinkingLevel,
            tokens: runtime.tokens,
            contextUsage: Self.contextUsage(runtime.contextUsage, applyingContextWindow: matchingModel?.contextWindow, tokens: runtime.tokens)
        )
    }

    private static func contextUsage(
        _ current: SessionContextUsage?,
        applyingContextWindow contextWindow: Int?,
        tokens totals: SessionTokenTotals
    ) -> SessionContextUsage? {
        let tokenCount = current?.tokens ?? (totals.total > 0 ? totals.total : 0)
        let percent: Double?
        if let contextWindow, contextWindow > 0 {
            percent = Double(tokenCount) / Double(contextWindow) * 100
        } else {
            percent = current?.percent
        }
        return SessionContextUsage(
            tokens: tokenCount,
            contextWindow: contextWindow ?? current?.contextWindow,
            percent: percent
        )
    }

    private static func modelDisplayName(provider: String?, modelID: String?, fallback: String) -> String {
        guard let modelID = modelID?.nilIfBlank else { return fallback }
        guard let provider = provider?.nilIfBlank else { return modelID }
        return "\(provider)/\(modelID)"
    }

    private static func contextUsageDisplayName(_ usage: SessionContextUsage?) -> String {
        guard let usage else { return "unknown" }
        let used = compactTokenCount(usage.tokens)
        let window = compactTokenCount(usage.contextWindow)
        if let percent = usage.percent {
            return "\(used)/\(window) · \(Int(percent.rounded()))%"
        }
        return "\(used)/\(window)"
    }

    private static func compactTokenCount(_ value: Int?) -> String {
        guard let value else { return "?" }
        if value < 1_000 { return "\(value)" }
        if value < 10_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        if value < 1_000_000 { return "\(Int(round(Double(value) / 1_000)))k" }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    private func sourceTaggedAppPrompt(_ text: String, sessionTitle: String) -> String {
        if text.range(of: #"^\[source:[^\]]+\]"#, options: .regularExpression) != nil {
            return text
        }
        let model = selectedSession == nil
            ? defaultModelDisplayName
            : (selectedModelDisplayName.nilIfBlank ?? selectedSession?.latestModel ?? defaultModelPreference?.id ?? "unknown")
        let thinking = selectedSession == nil ? defaultThinkingDisplayName : selectedThinkingLevel
        let fields = [
            "source:pi-ios-app",
            "type=text",
            "session=\"\(Self.sourceTagValue(sessionTitle))\"",
            "model=\"\(Self.sourceTagValue(model))\"",
            "thinking=\"\(Self.sourceTagValue(thinking))\""
        ]
        return "[\(fields.joined(separator: " "))]\n\(text)"
    }

    private static func sourceTagValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        if defaultRuntime != nil {
            saveSessionDefaultsCache()
            if selectedSession == nil {
                selectedRuntime = defaultRuntimeForDisplay
                availableModels = cachedSelectableAvailableModels
            }
        }
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

    private struct SessionDefaultsCacheSnapshot: Codable {
        let snapshot: SessionDefaultsSnapshot
        let loadedAt: Date
    }

    private func loadSessionDefaultsCache() {
        guard let data = defaults.data(forKey: sessionDefaultsCacheDefaultsKey),
              let decoded = try? JSONDecoder().decode(SessionDefaultsCacheSnapshot.self, from: data) else {
            return
        }
        defaultRuntime = decoded.snapshot.runtimeState
        sessionDefaultsCacheLoadedAt = decoded.loadedAt
        if !decoded.snapshot.availableModels.isEmpty {
            cachedAvailableModels = Self.selectableModels(from: decoded.snapshot.availableModels)
            availableModelsCacheLoadedAt = decoded.loadedAt
        }
        selectedRuntime = defaultRuntimeForDisplay
        availableModels = cachedSelectableAvailableModels
    }

    private func cacheSessionDefaults(_ snapshot: SessionDefaultsSnapshot, loadedAt: Date = Date()) {
        defaultRuntime = snapshot.runtimeState
        sessionDefaultsCacheLoadedAt = loadedAt
        if !snapshot.availableModels.isEmpty {
            cacheAvailableModels(snapshot.availableModels, loadedAt: loadedAt)
        }
        saveSessionDefaultsCache()
        selectedRuntime = selectedSession == nil ? defaultRuntimeForDisplay : selectedRuntime
    }

    private func saveSessionDefaultsCache() {
        guard let defaultRuntime,
              let loadedAt = sessionDefaultsCacheLoadedAt,
              let data = try? JSONEncoder().encode(SessionDefaultsCacheSnapshot(
                snapshot: SessionDefaultsSnapshot(runtimeState: defaultRuntime, availableModels: cachedAvailableModels),
                loadedAt: loadedAt
              )) else {
            defaults.removeObject(forKey: sessionDefaultsCacheDefaultsKey)
            return
        }
        defaults.set(data, forKey: sessionDefaultsCacheDefaultsKey)
    }

    private func saveHost() {
        let host = host
        if let data = try? JSONEncoder().encode(host) {
            defaults.set(data, forKey: hostDefaultsKey)
        }
        stopDeviceCommandRuntime()
        startDeviceCommandRuntime()
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
        stopDeviceCommandRuntime()
        startDeviceCommandRuntime()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var xmlEscapedForPrompt: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
