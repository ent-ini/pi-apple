import Foundation
import AppKit
import SwiftUI
import ApplePiCore
import ApplePiRemote

typealias PiCatalogLoader = @Sendable (PiHostConfiguration, String?) async throws -> PiCatalogSnapshot

private final class MainActorCallback: @unchecked Sendable {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction() {
        action()
    }
}

@MainActor
final class PiAppState: ObservableObject {
    @Published var host = PiHostConfiguration() {
        didSet {
            guard !isLoadingPersistedState else { return }
            // Any change to `host` (mode, hostname, user, port, identity file,
            // auth method) means the previous catalog and open tabs reference
            // a different machine. Always reset to a known-empty state and
            // kick off a fresh catalog load — never reuse the old project
            // working directory as filter context, since it is meaningless
            // on the new host.
            clearCatalog()
            saveHost()
            refreshConfigurationSummary()
            refreshCatalog(usesActiveProjectContext: false)
            // The previous host's stream is torn down inside `clearCatalog`;
            // start a fresh one for the new host.
            if startsBackgroundWork {
                startCatalogLiveUpdates()
                applyDiagnosticsGatewayPreference()
            }
        }
    }
    @Published private(set) var projects: [PiProject] = []
    @Published private(set) var sessions: [PiSessionSummary] = []
    /// Session IDs whose rename we have optimistically applied locally but the
    /// daemon has not yet acknowledged with a 200 to `POST /sessions/:id/name`.
    /// Catalog snapshots received in the meantime must keep the local title
    /// (instead of reverting to the pre-rename server title), or the user sees
    /// the sidebar flicker back to the old name until the rename RPC finally
    /// completes (which can take minutes for `set_session_name`).
    private var pendingRenames: Set<String> = []
    @Published var selection: PiSelection?
    @Published var sessionSearchText = ""
    @Published private(set) var pendingSessionSearchFocusRequest = false
    @Published private(set) var sessionSearchFocusRequestID = 0
    @Published var statusMessage = "Ready" {
        didSet {
            guard !isLoadingPersistedState,
                  oldValue != statusMessage else { return }
            DiagnosticsLogBuffer.shared.append(level: "info", category: "app.status", message: statusMessage)
        }
    }
    @Published var isLoadingCatalog = false
    @Published var showsNewSessionSheet = false
    @Published var newSessionWorkingDirectory = ""
    @Published var newSessionName = ""
    @Published var newSessionIsTemporary = false
    @Published private(set) var remoteDirectoryEntries: [RemoteDirectoryEntry] = []
    @Published private(set) var remoteDirectoryPath = ""
    @Published private(set) var remoteDirectoryParent: String?
    @Published private(set) var remoteDirectoryStatus = ""
    @Published private(set) var isLoadingRemoteDirectory = false
    @Published private(set) var configurationSummary = PiConfigurationSummary.empty(host: PiHostConfiguration())
    @Published var appearance = AppAppearance() {
        didSet {
            saveAppearance()
        }
    }
    @Published private(set) var shortcutPreferences = AppShortcutPreferences() {
        didSet {
            guard !isLoadingPersistedState else { return }
            saveShortcutPreferences()
        }
    }
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var sendingSessionKeys: Set<String> = []
    @Published private(set) var unreadSessionKeys: Set<String> = []
    @Published private(set) var sessionActivityOverrides: [String: Date] = [:]
    @Published private(set) var defaultModelPreference: DefaultModelPreference?
    @Published private(set) var isLoadingAvailableModels = false
    @Published private(set) var diagnosticsGatewayEnabled = false
    @Published private(set) var diagnosticsGatewayState = DiagnosticsGatewayState()

    let chatWorkspace = ChatSessionStore()

    private let updateCheckService: UpdateCheckService
    private let remoteDirectoryService: RemoteDirectoryService
    private let catalogLoader: PiCatalogLoader
    private let defaults: UserDefaults
    private let hostDefaultsKey = "ApplePi.host"
    private let appearanceDefaultsKey = "ApplePi.appearance"
    private let shortcutDefaultsKey = "ApplePi.shortcuts"
    private let chatTabDefaultsKey = "ApplePi.chatTabs"
    private let lastUpdateCheckKey = "ApplePi.updateCheck.lastCheckedAt"
    private let modelDefaultsKey = "ApplePi.modelDefaults"
    private let availableModelsCacheDefaultsKey = "ApplePi.availableModelsCache"
    private let diagnosticsGatewayEnabledDefaultsKey = "ApplePi.diagnosticsGateway.enabled"
    private let diagnosticsGatewayPort: UInt16 = 8765
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60
    private let startsBackgroundWork: Bool
    private let chatTabPersistence: ChatTabPersistence
    private let diagnosticsGateway = DiagnosticsHTTPGateway()
    private var isLoadingPersistedState = false
    private var catalogRefreshID = UUID()
    private var remoteDirectoryRefreshID = UUID()
    private var catalogPollingTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?
    private var selectedSessionPollingTask: Task<Void, Never>?
    private var selectedSessionStreamTask: Task<Void, Never>?
    private var selectedSessionCatchUpTask: Task<Void, Never>?
    private var selectedSessionStreamFlushTask: Task<Void, Never>?
    private var pendingSelectedSessionStreamPage: SessionEventsPage?
    private var pendingSelectedSessionStreamTabID: ChatSession.ID?
    private var pendingSelectedSessionStreamSessionID: String?
    private var turnStreamFlushTask: Task<Void, Never>?
    private var pendingTurnStreamEvents: [SessionEvent] = []
    private var pendingTurnStreamIsFinal = false
    private var pendingTurnStreamTabID: ChatSession.ID?
    private var pendingTurnStreamGeneration: Int?
    private var isSelectedSessionStreamConnected = false
    private var activityObservers: [NSObjectProtocol] = []
    private var isApplicationActive = true
    private var isCatalogStreamConnected = false
    /// Long-lived task that subscribes to the daemon's `/sessions/stream`
    /// SSE endpoint and pushes full catalog snapshots into `projects` /
    /// `sessions`. `nil` whenever the current host doesn't use the daemon
    /// transport or the task is not running.
    private var catalogStreamTask: Task<Void, Never>?
    /// Pending debounced save for the chat tabs snapshot. A single task
    /// is reused so a burst of mutations only writes once.
    private var chatTabsSaveTask: Task<Void, Never>?
    private var sessionDefaultsCache: [String: SessionDefaultsSnapshot] = [:]
    private var availableModelsCache: [PiModelOption] = []
    private var availableModelsCacheLoadedAt: Date?
    private var pendingThinkingLevelBySessionKey: [String: String] = [:]
    private var thinkingLevelMutationVersionBySessionKey: [String: Int] = [:]
    private var modelMutationVersionBySessionKey: [String: Int] = [:]
    private static let selectedSessionStreamRetryDelay: Duration = .milliseconds(250)
    private static let selectedSessionStreamCoalesceDelay: Duration = .milliseconds(80)
    private static let selectedSessionStreamImmediateFlushEventCount = 80
    private static let turnStreamCoalesceDelay: Duration = .milliseconds(120)
    private static let turnStreamImmediateFlushEventCount = 80

    init(
        defaults: UserDefaults = Foundation.UserDefaults.standard,
        configurationService: PiConfigurationService = PiConfigurationService(),
        updateCheckService: UpdateCheckService = UpdateCheckService(),
        remoteDirectoryService: RemoteDirectoryService = RemoteDirectoryService(),
        catalogLoader: @escaping PiCatalogLoader = { host, activeProjectDirectory in
            try await PiSessionCatalogService().loadCatalog(
                host: host,
                activeProjectDirectory: activeProjectDirectory
            )
        },
        startsBackgroundWork: Bool = true
    ) {
        self.defaults = defaults
        self.updateCheckService = updateCheckService
        self.remoteDirectoryService = remoteDirectoryService
        self.catalogLoader = catalogLoader
        self.startsBackgroundWork = startsBackgroundWork
        self.chatTabPersistence = ChatTabPersistence(
            defaults: defaults,
            defaultsKey: chatTabDefaultsKey
        )

        migrateLegacyDefaultsIfNeeded()
        isLoadingPersistedState = true
        loadHost()
        loadAppearance()
        loadShortcutPreferences()
        loadModelDefaults()
        loadAvailableModelsCache()
        loadDiagnosticsGatewayPreferences()
        isLoadingPersistedState = false
        RemoteDiagnostics.sink = { event in
            DiagnosticsLogBuffer.shared.append(
                level: event.level,
                category: event.category,
                message: event.message,
                metadata: event.metadata
            )
        }
        DiagnosticsLogBuffer.shared.append(level: "info", category: "app.lifecycle", message: "pi-app started")

        chatWorkspace.onSessionExit = { [weak self] in
            self?.scheduleCatalogRefresh()
        }
        // Persist whenever the user mutates the set of open tabs or
        // changes which one is selected. The save is debounced inside
        // `schedulePersistedChatTabsSave` so a burst of streaming
        // events only writes once.
        chatWorkspace.onTabsChanged = { [weak self] in
            self?.schedulePersistedChatTabsSave()
            self?.restartSelectedSessionEventStream()
        }
        // Restore previously open tabs before kicking off the catalog
        // refresh. A fingerprint mismatch (different host) is a no-op
        // and the snapshot is simply overwritten on the first save.
        restorePersistedChatTabs()
        refreshConfigurationSummary()
        if startsBackgroundWork {
            refreshCatalog()
            runUpdateCheckIfNeeded()
        }
        // The live subscription is independent of the one-shot refresh:
        // it stays alive across app sessions for daemon-backed hosts.
        if startsBackgroundWork {
            startApplicationActivityObservers()
            startCatalogLiveUpdates()
            startCatalogAdaptivePolling()
            startSelectedSessionEventPolling()
            restartSelectedSessionEventStream()
            applyDiagnosticsGatewayPreference()
        }
    }

    private func migrateLegacyDefaultsIfNeeded() {
        guard defaults === UserDefaults.standard else { return }
        let migrationMarker = "pi-app.defaultsMigration.com.dodoreach.ApplePi"
        guard !defaults.bool(forKey: migrationMarker) else { return }
        guard let legacyDomain = UserDefaults.standard.persistentDomain(forName: "com.dodoreach.ApplePi") else {
            defaults.set(true, forKey: migrationMarker)
            return
        }

        for key in [hostDefaultsKey, appearanceDefaultsKey, shortcutDefaultsKey, chatTabDefaultsKey, lastUpdateCheckKey, modelDefaultsKey, availableModelsCacheDefaultsKey] {
            guard defaults.object(forKey: key) == nil,
                  let value = legacyDomain[key] else { continue }
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migrationMarker)
    }

    func dismissAvailableUpdate() {
        availableUpdate = nil
    }

    /// Called from the app termination notification. Cancels background
    /// catalog work and active sends before the process exits, so a local
    /// `pi --mode rpc` child does not survive as an orphan when the user
    /// quits Apple Pi mid-turn.
    func shutdownForTermination() {
        catalogRefreshID = UUID()
        stopCatalogLiveUpdates()
        stopCatalogAdaptivePolling()
        selectedSessionPollingTask?.cancel()
        selectedSessionPollingTask = nil
        selectedSessionCatchUpTask?.cancel()
        selectedSessionCatchUpTask = nil
        stopSelectedSessionEventStream()
        turnStreamFlushTask?.cancel()
        turnStreamFlushTask = nil
        clearPendingTurnStreamEvents()
        diagnosticsGateway.stop()
        savePersistedChatTabs()
        for tab in chatWorkspace.tabs {
            tab.cancelSend()
        }
    }

    func setDiagnosticsGatewayEnabled(_ enabled: Bool) {
        diagnosticsGatewayEnabled = enabled
        defaults.set(enabled, forKey: diagnosticsGatewayEnabledDefaultsKey)
        applyDiagnosticsGatewayPreference()
    }

    var diagnosticsGatewayLogsURL: String {
        "\(diagnosticsGatewayState.baseURL)/diagnostics/logs?tail=500"
    }

    var diagnosticsGatewayHealthURL: String {
        "\(diagnosticsGatewayState.baseURL)/diagnostics/health"
    }

    var diagnosticsGatewayCurlCommand: String {
        "curl -H 'Authorization: Bearer $APPLEPI_TOKEN' '\(diagnosticsGatewayLogsURL)'"
    }

    private func loadDiagnosticsGatewayPreferences() {
        diagnosticsGatewayEnabled = defaults.bool(forKey: diagnosticsGatewayEnabledDefaultsKey)
        diagnosticsGatewayState = DiagnosticsGatewayState(isRunning: false, port: diagnosticsGatewayPort, message: "Diagnostics gateway is off.")
    }

    private func applyDiagnosticsGatewayPreference() {
        guard diagnosticsGatewayEnabled else {
            diagnosticsGateway.stop()
            diagnosticsGatewayState = DiagnosticsGatewayState(isRunning: false, port: diagnosticsGatewayPort, message: "Diagnostics gateway is off.")
            return
        }
        let gatewayHost = host
        diagnosticsGateway.start(
            port: diagnosticsGatewayPort,
            tokenProvider: {
                RemoteDaemonTokenStore.readToken(for: gatewayHost)
            },
            stateHandler: { [weak self] state in
                Task { @MainActor in
                    self?.diagnosticsGatewayState = state
                }
            },
            uiSnapshotProvider: { [weak self] in
                self?.diagnosticsUISnapshotJSON() ?? "{}\n"
            },
            transcriptProvider: { [weak self] in
                self?.diagnosticsTranscriptJSON() ?? "{}\n"
            },
            screenshotProvider: { [weak self] in
                self?.diagnosticsScreenshotPNG()
            }
        )
    }

    private func diagnosticsUISnapshotJSON() -> String {
        let selected = chatWorkspace.selectedTab
        let visibleWindows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
        let catalogSnapshot: [String: Any] = [
            "projects": projects.count,
            "sessions": sessions.count,
            "isCatalogStreamConnected": isCatalogStreamConnected,
            "isSelectedSessionStreamConnected": isSelectedSessionStreamConnected
        ]
        let workspaceSnapshot: [String: Any] = [
            "tabs": chatWorkspace.tabs.count,
            "selectedTabID": selected?.id.uuidString ?? "",
            "selectedSessionID": selected?.sessionID ?? "",
            "selectedTitle": selected?.title ?? "",
            "selectedEventCount": selected?.events.count ?? 0,
            "selectedFirstLine": selected?.firstPersistedLineIndex ?? -1,
            "selectedLastLine": selected?.lastPersistedLineIndex ?? -1,
            "hasEarlierHistory": selected?.hasEarlierHistory ?? false,
            "isLoadingEarlierHistory": selected?.isLoadingEarlierHistory ?? false,
            "isLoading": selected?.isLoading ?? false,
            "isSending": selected?.isSending ?? false,
            "isAwaitingTurnCommit": selected?.isAwaitingTurnCommit ?? false,
            "canAcceptSteering": selected?.canAcceptSteering ?? false,
            "hasActiveSend": selected?.hasActiveSend ?? false
        ]
        let windowSnapshots: [[String: Any]] = visibleWindows.map { window in
            let frame: [String: Any] = [
                "x": Int(window.frame.origin.x),
                "y": Int(window.frame.origin.y),
                "width": Int(window.frame.size.width),
                "height": Int(window.frame.size.height)
            ]
            return [
                "title": window.title,
                "isKey": window.isKeyWindow,
                "isMain": window.isMainWindow,
                "frame": frame
            ]
        }
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "host": host.remoteDaemonDisplayAddress,
            "statusMessage": statusMessage,
            "isLoadingCatalog": isLoadingCatalog,
            "catalog": catalogSnapshot,
            "workspace": workspaceSnapshot,
            "windows": windowSnapshots
        ]
        return Self.diagnosticsJSONString(payload)
    }

    private func diagnosticsTranscriptJSON() -> String {
        let selected = chatWorkspace.selectedTab
        let visibleEvents = selected?.events.filter(\.isVisibleInTranscript) ?? []
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "sessionID": selected?.sessionID ?? "",
            "title": selected?.title ?? "",
            "eventCount": selected?.events.count ?? 0,
            "visibleEventCount": visibleEvents.count,
            "firstLine": selected?.firstPersistedLineIndex ?? -1,
            "lastLine": selected?.lastPersistedLineIndex ?? -1,
            "hasEarlierHistory": selected?.hasEarlierHistory ?? false,
            "rows": visibleEvents.map(Self.diagnosticsEventSummary)
        ]
        return Self.diagnosticsJSONString(payload)
    }

    private func diagnosticsScreenshotPNG() -> Data? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized && $0.contentView != nil }),
              let contentView = window.contentView else {
            return nil
        }
        let bounds = contentView.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }

    private static func diagnosticsEventSummary(_ event: SessionEvent) -> [String: Any] {
        var summary: [String: Any] = [
            "id": event.id,
            "lineIndex": event.lineIndex,
            "preview": diagnosticsEventPreview(event)
        ]
        switch event {
        case .meta:
            summary["type"] = "meta"
        case .message(let message, _):
            summary["type"] = "message"
            summary["role"] = message.role.rawValue
            summary["contentBlocks"] = message.content.count
            summary["model"] = message.model ?? ""
        case .toolCall(let call, _):
            summary["type"] = "toolCall"
            summary["tool"] = call.name
        case .toolResult(let result, _):
            summary["type"] = "toolResult"
            summary["tool"] = result.toolName ?? ""
            summary["isError"] = result.isError
        case .other(let type, _):
            summary["type"] = "other"
            summary["eventType"] = type
        }
        return summary
    }

    private static func diagnosticsEventPreview(_ event: SessionEvent) -> String {
        let raw: String
        switch event {
        case .meta(let meta, _):
            raw = meta.displayName ?? meta.id
        case .message(let message, _):
            raw = message.content.map { block in
                switch block {
                case .text(let text): return text
                case .thinking(let text, _): return "[thinking] \(text)"
                case .image(let path, _): return "[image] \(path)"
                }
            }.joined(separator: " ")
        case .toolCall(let call, _):
            raw = "\(call.name) \(call.arguments)"
        case .toolResult(let result, _):
            raw = result.output
        case .other(let type, _):
            raw = type
        }
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(collapsed.prefix(500))
    }

    private static func diagnosticsJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return text + "\n"
    }

    private func runUpdateCheckIfNeeded() {
        let last = defaults.object(forKey: lastUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= updateCheckInterval else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                if let update = try await updateCheckService.checkForUpdate() {
                    self.availableUpdate = update
                }
                defaults.set(Date(), forKey: lastUpdateCheckKey)
            } catch {
                // Fail silently: the pill stays hidden, the next launch retries the check.
            }
        }
    }

    var selectedProject: PiProject? {
        guard case .project(let id) = selection else { return nil }
        return projects.first(where: { $0.id == id })
    }

    var selectedSession: PiSessionSummary? {
        guard case .session(let id) = selection else { return nil }
        return sessions.first(where: { $0.id == id || $0.filePath == id })
    }

    var activeProject: PiProject? {
        if let selectedProject { return selectedProject }
        if let selectedSession {
            return projects.first(where: { $0.id == selectedSession.projectID })
        }
        return projects.first
    }

    var filteredProjects: [PiProject] {
        projects
    }

    func sessions(for project: PiProject) -> [PiSessionSummary] {
        sessions
            .filter { $0.projectID == project.id }
            .sorted(by: sessionComesBefore)
    }

    func filteredSessions(for project: PiProject? = nil) -> [PiSessionSummary] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedSessions = project.map { sessions(for: $0) } ?? sessions.sorted(by: sessionComesBefore)

        guard !query.isEmpty else { return scopedSessions }
        return scopedSessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query) ||
            session.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    func effectiveLastActivity(for session: PiSessionSummary) -> Date {
        sessionAliases(for: session)
            .compactMap { sessionActivityOverrides[$0] }
            .max()
            .map { max($0, session.modifiedAt) }
            ?? session.modifiedAt
    }

    private func sessionComesBefore(_ lhs: PiSessionSummary, _ rhs: PiSessionSummary) -> Bool {
        let lhsActivity = effectiveLastActivity(for: lhs)
        let rhsActivity = effectiveLastActivity(for: rhs)
        if lhsActivity != rhsActivity {
            return lhsActivity > rhsActivity
        }
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    func isSessionSending(_ session: PiSessionSummary) -> Bool {
        let aliases = Set(sessionAliases(for: session))
        guard !aliases.isEmpty else { return false }
        return chatWorkspace.tabs.contains { tab in
            !aliases.isDisjoint(with: Set(sessionAliases(for: tab)))
                && (tab.hasActiveSend || tab.isSending || tab.isAwaitingTurnCommit || tab.canAcceptSteering)
        }
    }

    func isSelectedSession(_ session: PiSessionSummary) -> Bool {
        if case .session(let selectedID) = selection,
           selectedID == session.id || selectedID == session.filePath {
            return true
        }
        guard let tab = chatWorkspace.selectedTab else { return false }
        return !Set(sessionAliases(for: session)).isDisjoint(with: Set(sessionAliases(for: tab)))
    }

    func hasUnreadIndicator(_ session: PiSessionSummary) -> Bool {
        !isSessionSending(session) && !unreadSessionKeys.isDisjoint(with: Set(sessionAliases(for: session)))
    }

    var hasActiveSessionSearch: Bool {
        sessionSearchText.nilIfBlank != nil
    }

    func shortcut(for action: AppShortcutAction) -> AppShortcut {
        shortcutPreferences.binding(for: action)
    }

    func updateShortcut(_ shortcut: AppShortcut, for action: AppShortcutAction) {
        var next = shortcutPreferences
        next.set(shortcut, for: action)
        shortcutPreferences = next
    }

    func requestSessionSearchFocus() {
        pendingSessionSearchFocusRequest = true
        sessionSearchFocusRequestID &+= 1
    }

    func consumeSessionSearchFocusRequest() {
        pendingSessionSearchFocusRequest = false
    }

    func updateAppearance(_ update: (inout AppAppearance) -> Void) {
        var next = appearance
        update(&next)
        appearance = next
    }

    func updateNotificationPreferences(_ update: (inout TerminalNotificationPreferences) -> Void) {
        var next = appearance
        update(&next.notifications)
        appearance = next

        guard next.notifications.isEnabled else { return }
        Task {
            _ = await NativeNotificationPresenter.shared.prepareAuthorization(
                for: next.notifications
            )
        }
    }

    func sendTestNotification() async -> TerminalNotificationDeliveryResult {
        await NativeNotificationPresenter.shared.present(
            title: "pi-app",
            body: "OSC 777 notifications are ready.",
            preferences: appearance.notifications
        )
    }

    func refreshCatalog(usesActiveProjectContext: Bool = true, quietly: Bool = false) {
        isLoadingCatalog = true
        let refreshID = UUID()
        catalogRefreshID = refreshID
        let currentHost = host
        let activeProjectDirectory = usesActiveProjectContext ? activeProject?.workingDirectory : nil
        let catalogLoader = catalogLoader
        Task.detached {
            do {
                let snapshot = try await catalogLoader(currentHost, activeProjectDirectory)
                await MainActor.run {
                    guard self.catalogRefreshID == refreshID else { return }
                    self.projects = snapshot.projects
                    self.sessions = snapshot.sessions
                    self.preserveOpenChatSessionSidebarEntries()
                    self.sortCatalogState()
                    self.isLoadingCatalog = false
                    if !quietly {
                        self.statusMessage = PiAppState.catalogStatusMessage(
                            sessionCount: snapshot.sessions.count,
                            warnings: snapshot.warnings
                        )
                    }
                    self.repairSelectionIfNeeded()
                    self.refreshConfigurationSummary()
                    self.prefetchSessionDefaultsForCurrentContext()
                }
            } catch {
                await MainActor.run {
                    guard self.catalogRefreshID == refreshID else { return }
                    self.isLoadingCatalog = false
                    if !quietly {
                        self.statusMessage = error.localizedDescription
                        // Drop the stale data so the user is not looking at the
                        // old host's projects while the error banner is up.
                        self.projects = []
                        self.sessions = []
                        self.selection = nil
                    }
                }
            }
        }
    }

    func select(_ selection: PiSelection) {
        self.selection = selection
        if case .session = selection, let selectedSession {
            markSessionRead(selectedSession)
        }
        refreshConfigurationSummary()
        prefetchSessionDefaultsForCurrentContext()
        if case .session = selection, let selectedSession {
            resume(selectedSession)
        }
    }

    var selectedWorkingDirectory: String? {
        selectedSession?.workingDirectory ?? selectedProject?.workingDirectory
    }

    private var fallbackWorkingDirectory: String {
        host.defaultWorkingDirectory.nilIfBlank ?? "~/ai-agent/workspace"
    }

    private var preferredWorkingDirectory: String {
        fallbackWorkingDirectory
    }

    private func sessionDefaultsCacheKey(for workingDirectory: String?) -> String {
        let raw = workingDirectory?.nilIfBlank ?? fallbackWorkingDirectory
        return (raw as NSString).expandingTildeInPath
    }

    var cachedAvailableModels: [PiModelOption] {
        availableModelsCache
    }

    private func cacheAvailableModels(_ models: [PiModelOption], loadedAt: Date = Date()) {
        availableModelsCache = models
        availableModelsCacheLoadedAt = loadedAt
        saveAvailableModelsCache()
    }

    private func cacheSessionDefaults(_ snapshot: SessionDefaultsSnapshot, for workingDirectory: String?) {
        sessionDefaultsCache[sessionDefaultsCacheKey(for: workingDirectory)] = snapshot
        if !snapshot.availableModels.isEmpty {
            cacheAvailableModels(snapshot.availableModels)
        }
    }

    func setDefaultModelPreference(_ preference: DefaultModelPreference?) {
        defaultModelPreference = preference
        saveModelDefaults()
    }

    @discardableResult
    private func applyBestKnownSessionDefaults(to session: ChatSession) -> Bool {
        guard session.sessionID == nil,
              let request = session.launchRequest else {
            return false
        }

        guard let snapshot = sessionDefaultsCache[sessionDefaultsCacheKey(for: request.workingDirectory)] else {
            return false
        }

        var requestWithDefaults = request
        requestWithDefaults.applyDefaults(from: snapshot.runtimeState)
        session.updateLaunchRequest(requestWithDefaults)
        session.updateRuntimeState(runtime(snapshot.runtimeState, applying: requestWithDefaults))
        if session.availableModels.isEmpty {
            session.updateAvailableModels(snapshot.availableModels)
        }
        return true
    }

    private func prefetchSessionDefaultsForCurrentContext() {
        let workingDirectory = preferredWorkingDirectory
        let cacheKey = sessionDefaultsCacheKey(for: workingDirectory)
        if sessionDefaultsCache[cacheKey] != nil { return }

        let remoteAPIHost = host
        Task { [weak self] in
            do {
                let snapshot = try await RemoteDaemonClient().loadSessionDefaults(
                    host: remoteAPIHost,
                    workingDirectory: workingDirectory
                )
                await MainActor.run {
                    guard let self, self.host == remoteAPIHost else { return }
                    self.cacheSessionDefaults(snapshot, for: workingDirectory)
                }
            } catch {
                // Best-effort warmup only.
            }
        }
    }

    func presentNewSessionInFolder(isTemporary: Bool = false) {
        newSessionWorkingDirectory = preferredWorkingDirectory
        newSessionName = ""
        newSessionIsTemporary = isTemporary
        showsNewSessionSheet = true
    }

    func openNewSession() {
        openNewSession(
            workingDirectory: newSessionWorkingDirectory.nilIfBlank,
            sessionName: newSessionName.nilIfBlank,
            isTemporary: newSessionIsTemporary
        )
        resetNewSessionSheet()
    }

    func openNewSessionInCurrentFolder() {
        openNewSession(
            workingDirectory: preferredWorkingDirectory,
            sessionName: nil,
            isTemporary: false
        )
    }

    func openTemporarySessionInCurrentFolder() {
        openNewSession(
            workingDirectory: preferredWorkingDirectory,
            sessionName: nil,
            isTemporary: true
        )
    }

    func openNewSession(in workingDirectory: String?, isTemporary: Bool = false) {
        openNewSession(
            workingDirectory: workingDirectory,
            sessionName: nil,
            isTemporary: isTemporary
        )
    }

    func chooseNewSessionFolder() {
        refreshRemoteDirectory()
    }

    func refreshRemoteDirectory() {
        loadRemoteDirectory(newSessionWorkingDirectory.nilIfBlank ?? remoteDirectoryPath.nilIfBlank ?? "~")
    }

    func openRemoteDirectory(_ entry: RemoteDirectoryEntry) {
        newSessionWorkingDirectory = entry.path
        loadRemoteDirectory(entry.path)
    }

    func openRemoteDirectoryParent() {
        guard let remoteDirectoryParent else { return }
        newSessionWorkingDirectory = remoteDirectoryParent
        loadRemoteDirectory(remoteDirectoryParent)
    }

    func openRemoteHomeDirectory() {
        newSessionWorkingDirectory = "~"
        loadRemoteDirectory("~")
    }

    private func prepareRemoteDirectoryBrowserIfNeeded() {
        let initialPath = newSessionWorkingDirectory.nilIfBlank ?? remoteDirectoryPath.nilIfBlank ?? "~"
        newSessionWorkingDirectory = initialPath
        loadRemoteDirectory(initialPath)
    }

    private func loadRemoteDirectory(_ path: String) {
        isLoadingRemoteDirectory = true
        remoteDirectoryStatus = "Loading remote folders..."
        let refreshID = UUID()
        remoteDirectoryRefreshID = refreshID
        let currentHost = host
        let remoteDirectoryService = remoteDirectoryService
        Task.detached {
            do {
                let listing = try await remoteDirectoryService.listDirectories(host: currentHost, path: path)
                await MainActor.run {
                    guard self.remoteDirectoryRefreshID == refreshID else { return }
                    self.remoteDirectoryPath = listing.path
                    self.remoteDirectoryParent = listing.parent
                    self.remoteDirectoryEntries = listing.directories
                    self.newSessionWorkingDirectory = listing.path
                    self.isLoadingRemoteDirectory = false
                    self.remoteDirectoryStatus = listing.directories.isEmpty ? "No folders in this directory." : "\(listing.directories.count) folders"
                }
            } catch {
                await MainActor.run {
                    guard self.remoteDirectoryRefreshID == refreshID else { return }
                    self.remoteDirectoryEntries = []
                    self.isLoadingRemoteDirectory = false
                    self.remoteDirectoryStatus = error.localizedDescription
                }
            }
        }
    }

    private func openNewSession(workingDirectory: String?, sessionName: String?, isTemporary: Bool) {
        let effectiveName = sessionName?.nilIfBlank ?? (isTemporary ? "Temporary" : "New Pi")
        let request = PiLaunchRequest(
            workingDirectory: workingDirectory,
            sessionPath: nil,
            forkPath: nil,
            sessionName: sessionName?.nilIfBlank,
            isEphemeral: isTemporary,
            initialPrompt: nil,
            initialModelProvider: defaultModelPreference?.provider,
            initialModelID: defaultModelPreference?.modelID,
            initialThinkingLevel: defaultModelPreference?.thinkingLevel,
            hasExplicitInitialModel: defaultModelPreference != nil,
            hasExplicitInitialThinkingLevel: defaultModelPreference?.thinkingLevel?.nilIfBlank != nil
        )
        let key = "new:\(UUID().uuidString)"
        let tab = chatWorkspace.openTab(
            key: key,
            title: effectiveName,
            sessionPath: nil,
            launchRequest: request
        )
        _ = applyBestKnownSessionDefaults(to: tab)
        upsertSidebarSession(for: tab, fallbackWorkingDirectory: workingDirectory)
        hydratePendingSessionDefaults(for: tab)
        statusMessage = isTemporary ? "Started temporary Pi session" : "Started new Pi session"
    }

    private func resetNewSessionSheet() {
        newSessionName = ""
        newSessionIsTemporary = false
        showsNewSessionSheet = false
    }

    func openEphemeralSession() {
        openTemporarySessionInCurrentFolder()
    }

    func resume(_ session: PiSessionSummary) {
        let tab = chatWorkspace.openOrSelectTab(
            key: session.filePath,
            title: session.title,
            sessionID: session.id,
            sessionPath: session.filePath,
            eventLoader: eventLoader(for: session),
            historyPageLoader: historyPageLoader(for: session)
        )
        refreshSessionRuntime(for: tab)
        applyCachedAvailableModels(to: tab)
        statusMessage = "Resumed \(session.title)"
    }

    func fork(_ session: PiSessionSummary) {
        let request = PiLaunchRequest.fork(session)
        chatWorkspace.openTab(
            key: "fork:\(session.filePath):\(UUID().uuidString)",
            title: "Fork: \(session.title)",
            sessionPath: nil,
            launchRequest: request
        )
        statusMessage = "Fork ready from \(session.title)"
    }

    private func eventLoader(for session: PiSessionSummary) -> (@Sendable () async throws -> SessionEventsPage)? {
        remoteEventLoader(sessionID: session.id)
    }

    private func historyPageLoader(for session: PiSessionSummary) -> (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? {
        remoteHistoryPageLoader(sessionID: session.id)
    }

    private func remoteEventLoader(sessionID: String) -> (@Sendable () async throws -> SessionEventsPage)? {
        let remoteAPIHost = host
        return {
            try await RemoteDaemonClient().loadSessionEventPage(host: remoteAPIHost, sessionID: sessionID)
        }
    }

    private func remoteHistoryPageLoader(sessionID: String) -> (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? {
        let remoteAPIHost = host
        return { before, limit in
            try await RemoteDaemonClient().loadSessionEventPage(
                host: remoteAPIHost,
                sessionID: sessionID,
                limit: limit,
                before: before
            )
        }
    }

    func cancelSend(in session: ChatSession) {
        guard session.hasActiveSend else { return }
        statusMessage = "Aborting Pi..."
        let aliases = sessionAliases(for: session)
        setSessionSending(false, aliases: aliases)

        guard let sessionID = session.sessionID?.nilIfBlank else {
            session.abortSend()
            session.cancelSend()
            return
        }
        let remoteAPIHost = host
        // Important: do not cancel the send task / HTTP stream here. Abort
        // is an RPC command inside the active run; keeping the stream open
        // lets the app retain every message/tool event emitted before the
        // abort acknowledgement, matching TUI behavior.
        session.abortSend()
        Task { [weak self, weak session] in
            do {
                try await RemoteDaemonClient().abortSession(host: remoteAPIHost, sessionID: sessionID)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = error.localizedDescription
                    session?.applyStreamingEvents([.other(type: "abort_error", lineIndex: (session?.lastPersistedLineIndex ?? 0) + 1)], isFinal: false)
                }
            }
        }
    }

    func compactSession(_ session: ChatSession, instructions: String = "") {
        guard let sessionID = session.sessionID?.nilIfBlank else {
            statusMessage = "Compact is available after the remote session is created."
            return
        }
        guard !session.hasActiveSend else {
            statusMessage = "Wait for the current run to finish before compacting."
            return
        }
        statusMessage = "Compacting session..."
        let remoteAPIHost = host
        Task { [weak self, weak session] in
            do {
                try await RemoteDaemonClient().compactSession(
                    host: remoteAPIHost,
                    sessionID: sessionID,
                    instructions: instructions
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteAPIHost else { return }
                    self.statusMessage = "Compacted session"
                    session.loadFromDisk(force: true)
                    self.refreshSessionRuntime(for: session, updatesStatus: false)
                    self.scheduleCatalogRefresh(after: .milliseconds(100))
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func steerMessage(
        _ prompt: String,
        attachments: [ChatAttachment] = [],
        in session: ChatSession,
        onAccepted: (@MainActor () -> Void)? = nil
    ) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.hasActiveSend, session.canAcceptSteering else {
            return sendMessage(prompt, attachments: attachments, in: session, onAccepted: onAccepted)
        }
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        guard let sessionID = session.sessionID?.nilIfBlank else {
            statusMessage = "Steering is available after the remote session is created."
            return false
        }
        let effectivePrompt = trimmed.isEmpty ? "Please inspect the attached item(s)." : trimmed
        let taggedPrompt = sourceTaggedAppPrompt(effectivePrompt, session: session)
        statusMessage = "Sending to Pi..."
        // UI-wise queued input is just another user message. The daemon decides
        // whether /input becomes a fresh turn or active-run steering; the app
        // should render the accepted prompt immediately in both cases.
        session.appendSteeringPrompt(taggedPrompt, attachments: attachments)
        onAccepted?()
        let remoteAPIHost = host
        let steeringGeneration = session.currentSendGeneration
        Task { [weak self, weak session] in
            do {
                let daemonAttachments = try await self?.uploadAttachmentsIfNeeded(attachments) ?? []
                try await RemoteDaemonClient().submitSessionInput(
                    host: remoteAPIHost,
                    sessionID: sessionID,
                    prompt: taggedPrompt,
                    attachments: daemonAttachments
                )
                await MainActor.run {
                    guard let self, let session,
                          self.host == remoteAPIHost,
                          session.sessionID == sessionID,
                          session.currentSendGeneration == steeringGeneration,
                          session.hasActiveSend else { return }
                    self.statusMessage = "Sent to Pi"
                }
            } catch {
                await MainActor.run {
                    guard let self, let session else { return }
                    self.statusMessage = error.localizedDescription
                    if let remoteError = error as? RemoteDaemonError,
                       case .requestFailed(let status, _) = remoteError,
                       status == 409,
                       session.currentSendGeneration == steeringGeneration {
                        session.cancelSend()
                        session.finishSendingWithError(error.localizedDescription)
                        session.loadFromDisk(force: true)
                        self.setSessionSending(false, aliases: self.sessionAliases(for: session))
                        self.restartSelectedSessionEventStream()
                        self.scheduleCatalogRefresh(after: .milliseconds(50))
                        self.refreshSessionRuntime(for: session, updatesStatus: false)
                        return
                    }
                    session.applyStreamingEvents([.other(type: "steer_error", lineIndex: session.lastPersistedLineIndex + 1)], isFinal: false)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendMessage(
        _ prompt: String,
        attachments: [ChatAttachment] = [],
        in session: ChatSession,
        onAccepted: (@MainActor () -> Void)? = nil
    ) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        let effectivePrompt = trimmed.isEmpty ? "Please inspect the attached item(s)." : trimmed
        let taggedPrompt = sourceTaggedAppPrompt(effectivePrompt, session: session)
        if session.hasActiveSend && session.canAcceptSteering {
            return steerMessage(prompt, attachments: attachments, in: session, onAccepted: onAccepted)
        }
        if session.isSending || session.isAwaitingTurnCommit || session.hasActiveSend {
            // If the live run is no longer steerable, generation has ended and
            // this submit should become a normal new prompt. This mirrors TUI:
            // during generation -> steer, after generation -> next message.
            session.finishFinalizingForFollowUp()
            setSessionSending(false, aliases: sessionAliases(for: session))
        }

        if let request = session.launchRequest, request.isEphemeral {
            session.finishSendingWithError("Temporary chat sessions are not supported yet in pi-app.")
            return false
        }

        DiagnosticsLogBuffer.shared.append(
            level: "info",
            category: "send.lifecycle",
            message: "Send accepted",
            metadata: [
                "sessionID": session.sessionID ?? "",
                "sessionKey": session.key,
                "title": session.title,
                "attachments": String(attachments.count),
                "promptChars": String(effectivePrompt.count)
            ]
        )
        session.beginSending(prompt: taggedPrompt, attachments: attachments)
        let sendGeneration = session.currentSendGeneration
        let initialAliases = sessionAliases(for: session)
        markSessionActive(initialAliases)
        setSessionSending(true, aliases: initialAliases)
        clearUnread(aliases: initialAliases)
        promoteSidebarSession(for: session, fallbackAliases: initialAliases)
        statusMessage = "Sending to Pi..."
        onAccepted?()

        let task = Task { [weak self, weak session] in
            let outcome: SendOutcome
            if let self {
                outcome = await self.runRemoteTurn(
                    session: session,
                    prompt: taggedPrompt,
                    attachments: attachments,
                    sendGeneration: sendGeneration
                )
            } else {
                outcome = .cancelled
            }
            await MainActor.run {
                Self.applySendOutcome(
                    outcome,
                    session: session,
                    sendGeneration: sendGeneration,
                    initialAliases: initialAliases,
                    appState: self
                )
            }
        }
        session.sendTask = task
        return true
    }

    /// Outcome of a single send. The task body always funnels through
    /// `applySendOutcome` so success, failure, and cancellation take
    /// the same path: the session is mutated on the main actor only
    /// when it is still alive, and the send task reference is always
    /// cleared at the end.
    fileprivate enum SendOutcome: Sendable {
        case success
        case cancelled
        case failure(String)

        var diagnosticsName: String {
            switch self {
            case .success: return "success"
            case .cancelled: return "cancelled"
            case .failure: return "failure"
            }
        }
    }

    /// Apply the outcome of a send. Runs on the main actor; silently
    /// no-ops if the session has been deallocated (e.g. the tab was
    /// closed mid-send). Always clears `session.sendTask` so the store
    /// stops reporting the session as busy.
    fileprivate static func applySendOutcome(
        _ outcome: SendOutcome,
        session: ChatSession?,
        sendGeneration: Int,
        initialAliases: [String],
        appState: PiAppState?
    ) {
        defer {
            if session?.currentSendGeneration == sendGeneration {
                session?.sendTask = nil
            }
        }
        guard let session,
              session.currentSendGeneration == sendGeneration else { return }
        appState?.flushPendingTurnStreamEvents(for: session, generation: sendGeneration)
        DiagnosticsLogBuffer.shared.append(
            level: "info",
            category: "send.lifecycle",
            message: "Send completed",
            metadata: [
                "outcome": outcome.diagnosticsName,
                "sessionID": session.sessionID ?? "",
                "title": session.title,
                "generation": String(sendGeneration)
            ]
        )
        switch outcome {
        case .success:
            session.finishSendingAndReload()
            appState?.completeSend(for: session, fallbackAliases: initialAliases)
            appState?.statusMessage = "Pi replied"
            appState?.scheduleCatalogRefresh(after: .seconds(0.2))
        case .cancelled:
            // Cancellation is an expected user action (closing the
            // tab or switching hosts). Explicit user abort preserves
            // the optimistic transcript instead of clearing it.
            let wasAborted = session.hasAbortedCurrentSend
            session.finishSendingCancelled()
            let aliases = appState?.sessionAliases(for: session, fallback: initialAliases) ?? initialAliases
            appState?.setSessionSending(false, aliases: aliases)
            if !wasAborted {
                appState?.removeOptimisticSidebarSessionIfNeeded(matching: initialAliases)
            }
        case .failure(let message):
            session.finishSendingWithError(message)
            let aliases = appState?.sessionAliases(for: session, fallback: initialAliases) ?? initialAliases
            appState?.setSessionSending(false, aliases: aliases)
            appState?.removeOptimisticSidebarSessionIfNeeded(matching: initialAliases)
            appState?.statusMessage = message
        }
    }

    /// Runs the remote (pi-appd HTTP) send path. The session is
    /// captured weakly so closing the tab mid-send stops further
    /// mutations. Returns a `SendOutcome` for the caller to apply.
    ///
    /// The current release only reaches the daemon transport. This helper
    /// is the Remote API send entry point.
    private func runRemoteTurn(
        session: ChatSession?,
        prompt: String,
        attachments: [ChatAttachment],
        sendGeneration: Int
    ) async -> SendOutcome {
        let startedAt = Date()
        DiagnosticsLogBuffer.shared.append(
            level: "info",
            category: "send.remote",
            message: "Remote turn started",
            metadata: [
                "sessionID": session?.sessionID ?? "",
                "title": session?.title ?? "",
                "generation": String(sendGeneration),
                "attachments": String(attachments.count)
            ]
        )
        do {
            let daemonAttachments = try await self.uploadAttachmentsIfNeeded(attachments)
            // Remote turns must survive transient app/network loss; pi-appd persists JSONL
            // and the UI catches up later. Keep this explicit, source-tag heuristic is fallback only.
            let keepRunningOnDisconnect = true
            if let sessionID = session?.sessionID?.nilIfBlank {
                try await RemoteDaemonClient().streamSend(
                    host: self.host,
                    sessionID: sessionID,
                    prompt: prompt,
                    attachments: daemonAttachments,
                    keepRunningOnDisconnect: keepRunningOnDisconnect,
                    onEvent: { [weak self, weak session] event in
                        guard let self else { return }
                        await MainActor.run {
                            guard let session,
                                  session.currentSendGeneration == sendGeneration else { return }
                            self.applyTurnStreamEvent(event, to: session)
                        }
                    }
                )
            } else if let launchRequest = session?.launchRequest {
                let effectiveLaunchRequest = await remoteLaunchRequestApplyingFreshDefaults(launchRequest)
                try await RemoteDaemonClient().streamNewSession(
                    host: self.host,
                    request: effectiveLaunchRequest,
                    prompt: prompt,
                    attachments: daemonAttachments,
                    keepRunningOnDisconnect: keepRunningOnDisconnect,
                    onEvent: { [weak self, weak session] event in
                        guard let self else { return }
                        await MainActor.run {
                            guard let session,
                                  session.currentSendGeneration == sendGeneration else { return }
                            self.applyTurnStreamEvent(event, to: session)
                        }
                    }
                )
            } else {
                throw RemoteDaemonError.requestFailed(status: 400, body: "Session is missing an ID.")
            }
            DiagnosticsLogBuffer.shared.append(
                level: "info",
                category: "send.remote",
                message: "Remote turn finished",
                metadata: ["generation": String(sendGeneration), "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))]
            )
            return .success
        } catch is CancellationError {
            DiagnosticsLogBuffer.shared.append(
                level: "info",
                category: "send.remote",
                message: "Remote turn cancelled",
                metadata: ["generation": String(sendGeneration), "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))]
            )
            return .cancelled
        } catch {
            DiagnosticsLogBuffer.shared.append(
                level: "error",
                category: "send.remote",
                message: "Remote turn failed",
                metadata: ["generation": String(sendGeneration), "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)), "error": error.localizedDescription]
            )
            return .failure(error.localizedDescription)
        }
    }

    private func runtime(_ runtime: SessionRuntimeState, applying request: PiLaunchRequest) -> SessionRuntimeState {
        let provider = request.initialModelProvider?.nilIfBlank ?? runtime.provider
        let modelID = request.initialModelID?.nilIfBlank ?? runtime.modelID
        let thinkingLevel = request.initialThinkingLevel?.nilIfBlank ?? runtime.thinkingLevel
        guard provider != runtime.provider || modelID != runtime.modelID || thinkingLevel != runtime.thinkingLevel else {
            return runtime
        }
        return SessionRuntimeState(
            sessionID: runtime.sessionID,
            sessionPath: runtime.sessionPath,
            provider: provider,
            modelID: modelID,
            modelName: runtime.modelName,
            thinkingLevel: thinkingLevel,
            tokens: runtime.tokens,
            contextUsage: runtime.contextUsage
        )
    }

    private func remoteLaunchRequestApplyingFreshDefaults(_ launchRequest: PiLaunchRequest) async -> PiLaunchRequest {
        var request = launchRequest
        guard !request.hasExplicitInitialModel || !request.hasExplicitInitialThinkingLevel else {
            return request
        }

        do {
            let snapshot = try await RemoteDaemonClient().loadSessionDefaults(
                host: host,
                workingDirectory: request.workingDirectory
            )
            cacheSessionDefaults(snapshot, for: request.workingDirectory)
            request.applyDefaults(from: snapshot.runtimeState)
        } catch {
            if let snapshot = sessionDefaultsCache[sessionDefaultsCacheKey(for: request.workingDirectory)] {
                request.applyDefaults(from: snapshot.runtimeState)
            }
        }
        return request
    }

    private func enqueueTurnStreamEvents(_ events: [SessionEvent], isFinal: Bool, to session: ChatSession) {
        guard !events.isEmpty || isFinal else { return }

        let generation = session.currentSendGeneration
        if pendingTurnStreamTabID != session.id || pendingTurnStreamGeneration != generation {
            flushPendingTurnStreamEvents()
            pendingTurnStreamTabID = session.id
            pendingTurnStreamGeneration = generation
        }

        pendingTurnStreamEvents = compactTurnStreamEvents(pendingTurnStreamEvents + events)
        pendingTurnStreamIsFinal = pendingTurnStreamIsFinal || isFinal

        if isFinal || pendingTurnStreamEvents.count >= Self.turnStreamImmediateFlushEventCount {
            flushPendingTurnStreamEvents(for: session, generation: generation)
            return
        }

        guard turnStreamFlushTask == nil else { return }
        turnStreamFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.turnStreamCoalesceDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingTurnStreamEvents()
        }
    }

    private func flushPendingTurnStreamEvents(for expectedSession: ChatSession? = nil, generation expectedGeneration: Int? = nil) {
        turnStreamFlushTask?.cancel()
        turnStreamFlushTask = nil

        guard let tabID = pendingTurnStreamTabID,
              let generation = pendingTurnStreamGeneration else {
            clearPendingTurnStreamEvents()
            return
        }
        if let expectedSession, expectedSession.id != tabID {
            return
        }
        if let expectedGeneration, expectedGeneration != generation {
            return
        }

        let events = pendingTurnStreamEvents
        let isFinal = pendingTurnStreamIsFinal
        clearPendingTurnStreamEvents()

        let session = expectedSession ?? chatWorkspace.tabs.first(where: { $0.id == tabID })
        guard let session,
              session.currentSendGeneration == generation,
              !events.isEmpty || isFinal else {
            return
        }

        let previousTitle = session.title
        session.applyStreamingEvents(events, isFinal: isFinal)
        syncSidebarTitleIfNeeded(for: session, previousTitle: previousTitle)
    }

    private func clearPendingTurnStreamEvents() {
        pendingTurnStreamEvents = []
        pendingTurnStreamIsFinal = false
        pendingTurnStreamTabID = nil
        pendingTurnStreamGeneration = nil
    }

    private func compactTurnStreamEvents(_ events: [SessionEvent]) -> [SessionEvent] {
        var order: [String] = []
        var latestByID: [String: SessionEvent] = [:]
        order.reserveCapacity(events.count)
        for event in events {
            let id = event.id
            if latestByID[id] == nil {
                order.append(id)
            }
            latestByID[id] = event
        }
        return order.compactMap { latestByID[$0] }
    }

    private func applyTurnStreamEvent(_ event: PiTurnStreamEvent, to session: ChatSession) {
        switch event {
        case .sessionBound(let binding):
            let previousAliases = sessionAliases(for: session)
            let incomingTitle = binding.title.nilIfBlank
            let preservesExistingTitle = binding.sessionID != nil && binding.sessionID == session.sessionID
            let title = incomingTitle == nil || incomingTitle == "Pi" || preservesExistingTitle
                ? session.title
                : incomingTitle!
            let eventLoader = binding.sessionID.flatMap { remoteEventLoader(sessionID: $0) }
            let historyPageLoader = binding.sessionID.flatMap { remoteHistoryPageLoader(sessionID: $0) }
            session.bindToSession(
                key: binding.key,
                title: title,
                sessionID: binding.sessionID,
                sessionPath: binding.sessionPath,
                eventLoader: eventLoader,
                historyPageLoader: historyPageLoader
            )
            migrateSessionState(from: previousAliases, to: sessionAliases(for: session))
            chatWorkspace.closeDuplicateTabs(keeping: session, matchingAliases: sessionAliases(for: session))
            upsertSidebarSession(for: session, previousAliases: previousAliases, fallbackWorkingDirectory: binding.workingDirectory)
            // The key changed from `new:<UUID>` to the real file path,
            // so the persisted tabs snapshot is now stale. Save again.
            schedulePersistedChatTabsSave()
            if !session.isSending {
                restartSelectedSessionEventStream()
                scheduleCatalogRefresh(after: .milliseconds(50))
                refreshSessionRuntime(for: session, updatesStatus: false)
            }
            applyCachedAvailableModels(to: session)
        case .sessionHeader(let meta):
            if session.sessionID == nil {
                let previousAliases = sessionAliases(for: session)
                session.bindToSession(
                    sessionID: meta.id,
                    sessionPath: session.sessionPath,
                    eventLoader: session.sessionPath == nil ? remoteEventLoader(sessionID: meta.id) : nil,
                    historyPageLoader: remoteHistoryPageLoader(sessionID: meta.id)
                )
                migrateSessionState(from: previousAliases, to: sessionAliases(for: session))
                chatWorkspace.closeDuplicateTabs(keeping: session, matchingAliases: sessionAliases(for: session))
                upsertSidebarSession(for: session, previousAliases: previousAliases, fallbackWorkingDirectory: meta.workingDirectory)
                schedulePersistedChatTabsSave()
                if !session.isSending {
                    restartSelectedSessionEventStream()
                    scheduleCatalogRefresh(after: .milliseconds(50))
                    refreshSessionRuntime(for: session, updatesStatus: false)
                }
                applyCachedAvailableModels(to: session)
            }
        case .sessionEvents(let events, let isFinal):
            enqueueTurnStreamEvents(events, isFinal: isFinal, to: session)
        case .turnEnd:
            // A turn boundary is not necessarily the end of the live agent run:
            // queued steering can be consumed after the current turn finishes.
            // Keep the session steerable until agent_end/output_complete.
            break
        case .agentEnd:
            flushPendingTurnStreamEvents(for: session, generation: session.currentSendGeneration)
            session.markTurnOutputComplete()
        case .abort:
            // Abort is an event inside the current live run, not the end of the
            // client stream. Keep sendTask/isSending intact until output_complete
            // so any follow-up typed before stream close is routed as steer.
            flushPendingTurnStreamEvents(for: session, generation: session.currentSendGeneration)
            session.recordAbortAcknowledged()
            setSessionSending(false, aliases: sessionAliases(for: session))
        case .outputComplete:
            flushPendingTurnStreamEvents(for: session, generation: session.currentSendGeneration)
            if !session.hasAbortedCurrentSend {
                session.finishSendingAndReload()
                setSessionSending(false, aliases: sessionAliases(for: session))
            }
            restartSelectedSessionEventStream()
            scheduleCatalogRefresh(after: .milliseconds(50))
            refreshSessionRuntime(for: session, updatesStatus: false)
        case .streamError(let message):
            statusMessage = message
        }
    }

    func hydratePendingSessionDefaults(for session: ChatSession) {
        guard session.sessionID == nil,
              let launchRequest = session.launchRequest else { return }

        _ = applyBestKnownSessionDefaults(to: session)

        let remoteAPIHost = host
        Task { [weak self, weak session] in
            do {
                let snapshot = try await RemoteDaemonClient().loadSessionDefaults(
                    host: remoteAPIHost,
                    workingDirectory: launchRequest.workingDirectory
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteAPIHost, session.sessionID == nil else { return }
                    self.cacheSessionDefaults(snapshot, for: launchRequest.workingDirectory)
                    var request = session.launchRequest ?? launchRequest
                    request.applyDefaults(from: snapshot.runtimeState)
                    session.updateLaunchRequest(request)
                    session.updateRuntimeState(self.runtime(snapshot.runtimeState, applying: request))
                    session.updateAvailableModels(snapshot.availableModels)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshSessionRuntime(for session: ChatSession, updatesStatus: Bool = false) {
        guard let sessionID = session.sessionID?.nilIfBlank else {
            hydratePendingSessionDefaults(for: session)
            return
        }
        guard !sessionID.hasPrefix("new:"), !sessionID.hasPrefix("fork:") else { return }

        let remoteAPIHost = host
        let sessionKey = runtimeSessionKey(for: session)
        let observedThinkingMutationVersion = thinkingLevelMutationVersionBySessionKey[sessionKey] ?? 0
        Task { [weak self, weak session] in
            do {
                let runtime = try await RemoteDaemonClient().loadSessionRuntime(
                    host: remoteAPIHost,
                    sessionID: sessionID
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteAPIHost else { return }
                    guard (self.thinkingLevelMutationVersionBySessionKey[sessionKey] ?? 0) == observedThinkingMutationVersion else { return }
                    let effectiveRuntime = self.runtimeApplyingKnownModelContext(
                        self.runtimeApplyingPendingThinkingLevel(runtime, sessionKey: sessionKey)
                    )
                    session.updateRuntimeState(effectiveRuntime)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if updatesStatus {
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func refreshAvailableModels(for session: ChatSession, force: Bool = false) {
        if !force, !session.availableModels.isEmpty { return }
        if applyCachedAvailableModels(to: session) { return }
        refreshAvailableModelsCache(force: force, targetSession: session)
    }

    func refreshAvailableModelsCache(force: Bool = false) {
        refreshAvailableModelsCache(force: force, targetSession: nil)
    }

    private func refreshAvailableModelsCache(force: Bool, targetSession: ChatSession?) {
        if !force, !availableModelsCache.isEmpty { return }
        if isLoadingAvailableModels { return }

        isLoadingAvailableModels = true
        let remoteAPIHost = host
        Task { [weak self, weak targetSession] in
            do {
                let models = try await RemoteDaemonClient().loadAvailableModels(host: remoteAPIHost)
                await MainActor.run {
                    guard let self, self.host == remoteAPIHost else { return }
                    self.cacheAvailableModels(models)
                    self.isLoadingAvailableModels = false
                    for tab in self.chatWorkspace.tabs where tab.availableModels.isEmpty {
                        tab.updateAvailableModels(models)
                    }
                    if let targetSession {
                        targetSession.updateAvailableModels(models)
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

    @discardableResult
    private func applyCachedAvailableModels(to session: ChatSession) -> Bool {
        guard !availableModelsCache.isEmpty else { return false }
        if session.availableModels.isEmpty {
            session.updateAvailableModels(availableModelsCache)
        }
        return true
    }

    func selectModel(_ model: PiModelOption, in session: ChatSession) {
        if session.sessionID == nil {
            if var request = session.launchRequest {
                request.initialModelProvider = model.provider
                request.initialModelID = model.modelID
                request.hasExplicitInitialModel = true
                session.updateLaunchRequest(request)
            }
            if let current = session.runtimeState {
                session.updateRuntimeState(runtime(current, applyingSelectedModel: model))
            }
            statusMessage = "Model: \(model.shortLabel)"
            return
        }

        guard let sessionID = session.sessionID?.nilIfBlank else {
            statusMessage = "Model selection is available after the session starts."
            return
        }

        if let current = session.runtimeState {
            session.updateRuntimeState(runtime(current, applyingSelectedModel: model))
        }

        let sessionKey = runtimeSessionKey(for: session)
        let mutationVersion = nextModelMutationVersion(for: sessionKey)
        let remoteAPIHost = host
        statusMessage = "Switching model..."
        Task { [weak self, weak session] in
            do {
                let runtime = try await RemoteDaemonClient().setSessionModel(
                    host: remoteAPIHost,
                    sessionID: sessionID,
                    provider: model.provider,
                    modelID: model.modelID
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteAPIHost else { return }
                    guard (self.modelMutationVersionBySessionKey[sessionKey] ?? 0) == mutationVersion else { return }
                    session.updateRuntimeState(self.runtime(runtime, applyingSelectedModel: model))
                    self.statusMessage = "Model: \(runtime.modelDisplayName)"
                }
            } catch {
                await MainActor.run {
                    guard let self, let session else { return }
                    guard (self.modelMutationVersionBySessionKey[sessionKey] ?? 0) == mutationVersion else { return }
                    self.statusMessage = error.localizedDescription
                    self.refreshSessionRuntime(for: session, updatesStatus: false)
                }
            }
        }
    }

    func cycleThinkingLevel(in session: ChatSession) {
        if session.sessionID == nil {
            let nextLevel = nextThinkingLevel(after: session.runtimeState?.thinkingLevel ?? "off")
            if var request = session.launchRequest {
                request.initialThinkingLevel = nextLevel
                request.hasExplicitInitialThinkingLevel = true
                session.updateLaunchRequest(request)
            }
            if let current = session.runtimeState {
                session.updateRuntimeState(
                    SessionRuntimeState(
                        sessionID: current.sessionID,
                        sessionPath: current.sessionPath,
                        provider: current.provider,
                        modelID: current.modelID,
                        modelName: current.modelName,
                        thinkingLevel: nextLevel,
                        tokens: current.tokens,
                        contextUsage: current.contextUsage
                    )
                )
            }
            statusMessage = "Thinking: \(nextLevel)"
            return
        }

        guard let sessionID = session.sessionID?.nilIfBlank else {
            statusMessage = "Thinking level is available after the session starts."
            return
        }

        let currentLevel = effectiveThinkingLevel(for: session)
        let nextLevel = nextThinkingLevel(after: currentLevel)
        let sessionKey = runtimeSessionKey(for: session)
        let mutationVersion = nextThinkingLevelMutationVersion(for: sessionKey)
        pendingThinkingLevelBySessionKey[sessionKey] = nextLevel

        if let current = session.runtimeState {
            session.updateRuntimeState(
                SessionRuntimeState(
                    sessionID: current.sessionID,
                    sessionPath: current.sessionPath,
                    provider: current.provider,
                    modelID: current.modelID,
                    modelName: current.modelName,
                    thinkingLevel: nextLevel,
                    tokens: current.tokens,
                    contextUsage: current.contextUsage
                )
            )
        }
        statusMessage = "Thinking: \(nextLevel)"

        let remoteAPIHost = host
        Task { [weak self, weak session] in
            do {
                let runtime = try await RemoteDaemonClient().setSessionThinkingLevel(
                    host: remoteAPIHost,
                    sessionID: sessionID,
                    level: nextLevel
                )
                await MainActor.run {
                    guard let self, let session, self.host == remoteAPIHost else { return }
                    guard self.thinkingLevelMutationVersionBySessionKey[sessionKey] == mutationVersion else { return }
                    self.pendingThinkingLevelBySessionKey.removeValue(forKey: sessionKey)
                    session.updateRuntimeState(runtime)
                    self.statusMessage = "Thinking: \(runtime.thinkingLevel)"
                }
            } catch {
                await MainActor.run {
                    guard let self, let session else { return }
                    guard self.thinkingLevelMutationVersionBySessionKey[sessionKey] == mutationVersion else { return }
                    self.pendingThinkingLevelBySessionKey.removeValue(forKey: sessionKey)
                    self.statusMessage = error.localizedDescription
                    self.refreshSessionRuntime(for: session, updatesStatus: false)
                }
            }
        }
    }

    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]

    private func nextThinkingLevel(after currentLevel: String) -> String {
        let normalized = currentLevel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let index = Self.thinkingLevels.firstIndex(of: normalized) else {
            return "off"
        }
        return Self.thinkingLevels[(index + 1) % Self.thinkingLevels.count]
    }

    private func effectiveThinkingLevel(for session: ChatSession) -> String {
        let sessionKey = runtimeSessionKey(for: session)
        if let pending = pendingThinkingLevelBySessionKey[sessionKey]?.nilIfBlank {
            return pending
        }
        return session.runtimeState?.thinkingLevel ?? "off"
    }

    private func runtimeSessionKey(for session: ChatSession) -> String {
        if let sessionID = session.sessionID?.nilIfBlank {
            return "id:\(sessionID)"
        }
        if let sessionPath = session.sessionPath?.nilIfBlank {
            return "path:\(sessionPath)"
        }
        return "key:\(session.key)"
    }

    private func nextModelMutationVersion(for sessionKey: String) -> Int {
        let next = (modelMutationVersionBySessionKey[sessionKey] ?? 0) + 1
        modelMutationVersionBySessionKey[sessionKey] = next
        return next
    }

    private func nextThinkingLevelMutationVersion(for sessionKey: String) -> Int {
        let next = (thinkingLevelMutationVersionBySessionKey[sessionKey] ?? 0) + 1
        thinkingLevelMutationVersionBySessionKey[sessionKey] = next
        return next
    }

    private func runtimeApplyingPendingThinkingLevel(_ runtime: SessionRuntimeState, sessionKey: String) -> SessionRuntimeState {
        guard let pendingLevel = pendingThinkingLevelBySessionKey[sessionKey]?.nilIfBlank,
              pendingLevel != runtime.thinkingLevel else {
            return runtime
        }
        return SessionRuntimeState(
            sessionID: runtime.sessionID,
            sessionPath: runtime.sessionPath,
            provider: runtime.provider,
            modelID: runtime.modelID,
            modelName: runtime.modelName,
            thinkingLevel: pendingLevel,
            tokens: runtime.tokens,
            contextUsage: runtime.contextUsage
        )
    }

    private func runtimeApplyingKnownModelContext(_ runtime: SessionRuntimeState) -> SessionRuntimeState {
        guard let provider = runtime.provider?.nilIfBlank,
              let modelID = runtime.modelID?.nilIfBlank,
              let model = availableModelsCache.first(where: { $0.provider == provider && $0.modelID == modelID }),
              model.contextWindow != nil else {
            return runtime
        }
        return self.runtime(runtime, applyingSelectedModel: model)
    }

    private func runtime(_ runtime: SessionRuntimeState, applyingSelectedModel model: PiModelOption) -> SessionRuntimeState {
        SessionRuntimeState(
            sessionID: runtime.sessionID,
            sessionPath: runtime.sessionPath,
            provider: model.provider,
            modelID: model.modelID,
            modelName: model.name,
            thinkingLevel: runtime.thinkingLevel,
            tokens: runtime.tokens,
            contextUsage: contextUsage(runtime.contextUsage, applyingContextWindow: model.contextWindow, tokens: runtime.tokens)
        )
    }

    private func contextUsage(
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

    func rename(_ session: PiSessionSummary, to proposedTitle: String) {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let previous = session
        applyRenamedSession(previous, title: title)
        statusMessage = "Renamed \(previous.title)"

        let remoteAPIHost = host
        pendingRenames.insert(previous.id)
        Task { [weak self] in
            do {
                let updated = try await RemoteDaemonClient().renameSession(
                    host: remoteAPIHost,
                    sessionID: previous.id,
                    name: title
                )
                await MainActor.run {
                    guard let self, self.host == remoteAPIHost else { return }
                    self.pendingRenames.remove(updated.id)
                    self.upsertCatalogSession(updated)
                    self.syncOpenTabTitles(with: updated)
                    self.sortCatalogState()
                    self.repairSelectionIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.host == remoteAPIHost else { return }
                    self.pendingRenames.remove(previous.id)
                    self.upsertCatalogSession(previous)
                    self.syncOpenTabTitles(with: previous)
                    self.sortCatalogState()
                    self.statusMessage = "Could not rename \(previous.title): \(error.localizedDescription)"
                }
            }
        }
    }

    func delete(_ session: PiSessionSummary) {
        statusMessage = "Remote session deletion is not supported from pi-app."
    }

    @discardableResult
    func saveRemoteDaemonToken(_ token: String, for targetHost: PiHostConfiguration? = nil) -> String? {
        do {
            try RemoteDaemonTokenStore.saveToken(token, for: targetHost ?? host)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func clearRemoteDaemonToken(for targetHost: PiHostConfiguration? = nil) -> String? {
        do {
            try RemoteDaemonTokenStore.deleteToken(for: targetHost ?? host)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func hasRemoteDaemonTokenStored(for targetHost: PiHostConfiguration? = nil) -> Bool {
        RemoteDaemonTokenStore.hasToken(for: targetHost ?? host)
    }

    @discardableResult
    func saveGroqAPIKey(_ token: String) -> String? {
        do {
            try GroqAPIKeyStore.saveKey(token)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func clearGroqAPIKey() -> String? {
        do {
            try GroqAPIKeyStore.deleteKey()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func hasGroqAPIKeyStored() -> Bool {
        GroqAPIKeyStore.hasKey()
    }

    func groqAPIKey() -> String? {
        GroqAPIKeyStore.readKey()
    }

    private func scheduleCatalogRefresh(after delay: Duration = .seconds(1)) {
        catalogRefreshTask?.cancel()
        catalogRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.refreshCatalog()
                self.catalogRefreshTask = nil
            }
        }
    }

    func refreshConfigurationSummary() {
        configurationSummary = PiConfigurationSummary.remote(
            host: host,
            projectDirectory: activeProject?.workingDirectory
        )
    }

    func openGlobalSettings() {
        openPath(configurationSummary.globalSettingsPath)
    }

    func revealAgentDirectory() {
        revealPath(configurationSummary.agentDirectoryPath)
    }

    func openConfigurationMetric(_ metric: PiConfigurationMetric) {
        switch metric {
        case .config:
            openFirstOrReveal(paths: configurationSummary.settingsPaths, fallback: configurationSummary.agentDirectoryPath)
        case .instructions:
            openFirstOrReveal(paths: configurationSummary.contextFilePaths, fallback: configurationSummary.projectDirectory ?? configurationSummary.agentDirectoryPath)
        case .resources:
            revealPath(configurationSummary.resourceRootPaths.first ?? configurationSummary.agentDirectoryPath)
        }
    }

    func openProjectSettings(for project: PiProject? = nil) {
        let path = project?.workingDirectory.map { "\($0)/.pi/settings.json" } ?? configurationSummary.projectSettingsPath
        openPath(path)
    }

    func openAgentsFile(for project: PiProject? = nil) {
        guard let directory = project?.workingDirectory ?? configurationSummary.projectDirectory else { return }
        let candidates = ["\(directory)/AGENTS.md", "\(directory)/.pi/AGENTS.md"]
        openPath(candidates.first(where: { Foundation.FileManager().fileExists(atPath: $0) }))
    }

    func revealProjectDirectory(for project: PiProject) {
        revealPath(project.workingDirectory)
    }

    func revealProjectPiDirectory(for project: PiProject? = nil) {
        guard let directory = project?.workingDirectory ?? configurationSummary.projectDirectory else { return }
        revealPath("\(directory)/.pi")
    }

    func pathExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return Foundation.FileManager().fileExists(atPath: path)
    }

    private func sortCatalogState() {
        sessions.sort(by: sessionComesBefore)
        projects.sort { lhs, rhs in
            let lhsActivity = lhs.lastActivity ?? .distantPast
            let rhsActivity = rhs.lastActivity ?? .distantPast
            if lhsActivity != rhsActivity {
                return lhsActivity > rhsActivity
            }
            if lhs.title.localizedCaseInsensitiveCompare(rhs.title) != .orderedSame {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private func repairSelectionIfNeeded() {
        defer { refreshConfigurationSummary() }

        if let tab = chatWorkspace.selectedTab {
            let aliases = Set(sessionAliases(for: tab))
            if let matched = sessions.first(where: { !aliases.isDisjoint(with: Set(sessionAliases(for: $0))) }) {
                selection = .session(matched.id)
                return
            }
            if tab.isSending || tab.sessionID != nil || tab.launchRequest != nil {
                upsertSidebarSession(for: tab)
                return
            }
        }

        guard let selection else { return }
        switch selection {
        case .project(let id):
            if !projects.contains(where: { $0.id == id }) {
                self.selection = nil
            }
        case .session(let id):
            if let matched = sessions.first(where: { $0.id == id || $0.filePath == id }) {
                self.selection = .session(matched.id)
            } else {
                self.selection = nil
            }
        }
    }

    private func clearCatalog() {
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        projects = []
        sessions = []
        selection = nil
        sendingSessionKeys = []
        unreadSessionKeys = []
        sessionActivityOverrides = [:]
        sessionDefaultsCache = [:]
        availableModelsCache = []
        availableModelsCacheLoadedAt = nil
        isLoadingAvailableModels = false
        // Open chat tabs reference `sessionPath` values from the previous
        // host, so close them. Without this the user sees stale
        // conversations after a host change.
        chatWorkspace.closeAll(notify: false)
        // Also wipe the remote directory browser state — it is per-host and
        // would otherwise flash stale entries when the user reopens the
        // "New Session in Folder" sheet.
        remoteDirectoryEntries = []
        remoteDirectoryPath = ""
        remoteDirectoryParent = nil
        remoteDirectoryStatus = ""
        newSessionWorkingDirectory = ""
        // Stop live SSE subscriptions — they are tied to the old host.
        stopSelectedSessionEventStream()
        stopCatalogLiveUpdates()
    }

    // MARK: - Live catalog subscription

    /// Starts (or restarts) the long-lived SSE subscription for the
    /// current remote daemon host.
    private func startCatalogLiveUpdates() {
        stopCatalogLiveUpdates()
        let streamHost = host
        catalogStreamTask = Task { [weak self] in
            await self?.runCatalogLiveUpdates(host: streamHost)
        }
    }

    /// Cancels the SSE subscription, if any. Safe to call from any
    /// state — including when no task is running.
    private func stopCatalogLiveUpdates() {
        catalogStreamTask?.cancel()
        catalogStreamTask = nil
        isCatalogStreamConnected = false
    }

    private func startCatalogAdaptivePolling() {
        catalogPollingTask?.cancel()
        catalogPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval: Duration = self.isApplicationActive ? .seconds(3) : .seconds(30)
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard !self.isLoadingCatalog,
                      !self.isCatalogStreamConnected else { continue }
                self.refreshCatalog(quietly: true)
            }
        }
    }

    private func stopCatalogAdaptivePolling() {
        catalogPollingTask?.cancel()
        catalogPollingTask = nil
    }

    private func startApplicationActivityObservers() {
        guard activityObservers.isEmpty else { return }
        isApplicationActive = NSApp?.isActive ?? true
        let center = NotificationCenter.default
        activityObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isApplicationActive = true
                    if !self.isLoadingCatalog,
                       !self.isCatalogStreamConnected {
                        self.refreshCatalog(quietly: true)
                    }
                    await self.syncSelectedRemoteSessionDelta()
                }
            }
        )
        activityObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isApplicationActive = false
                }
            }
        )
    }

    private func restartSelectedSessionEventStream() {
        stopSelectedSessionEventStream()
        guard startsBackgroundWork,
              let session = chatWorkspace.selectedTab,
              let sessionID = session.sessionID?.nilIfBlank,
              !sessionID.hasPrefix("new:"),
              !sessionID.hasPrefix("fork:") else { return }

        // Wait until the initial page has loaded before opening the SSE tail.
        // Otherwise `lastPersistedLineIndex` is still -1 and the daemon has to
        // replay the whole JSONL history for large sessions, only for the UI to
        // drop most of it while `isLoading` is true.
        guard !session.isLoading, session.lastPersistedLineIndex >= 0 else {
            let selectedTabID = session.id
            selectedSessionStreamTask = Task { [weak self] in
                try? await Task.sleep(for: Self.selectedSessionStreamRetryDelay)
                guard !Task.isCancelled else { return }
                self?.restartSelectedSessionEventStreamIfStillSelected(selectedTabID: selectedTabID)
            }
            return
        }

        // Skeleton: show the runtime immediately from the cached JSONL
        // parse (handled inside the fast runtime endpoint) so the
        // model/thinking chip is never blank while the stream warms up.
        refreshSessionRuntime(for: session)

        DiagnosticsLogBuffer.shared.append(
            level: "info",
            category: "session.stream",
            message: "Restarting selected session stream",
            metadata: ["sessionID": sessionID, "after": String(session.lastPersistedLineIndex), "title": session.title]
        )
        let streamHost = host
        let selectedTabID = session.id
        selectedSessionStreamTask = Task { [weak self] in
            await self?.runSelectedSessionEventStream(
                host: streamHost,
                sessionID: sessionID,
                selectedTabID: selectedTabID
            )
        }
    }

    private func stopSelectedSessionEventStream() {
        selectedSessionStreamTask?.cancel()
        selectedSessionStreamTask = nil
        selectedSessionCatchUpTask?.cancel()
        selectedSessionCatchUpTask = nil
        cancelSelectedSessionStreamFlush(discardPending: true)
        isSelectedSessionStreamConnected = false
    }

    private func restartSelectedSessionEventStreamIfStillSelected(selectedTabID: ChatSession.ID) {
        guard chatWorkspace.selectedTab?.id == selectedTabID else { return }
        restartSelectedSessionEventStream()
    }

    private func runSelectedSessionEventStream(
        host streamHost: PiHostConfiguration,
        sessionID: String,
        selectedTabID: ChatSession.ID
    ) async {
        let client = RemoteDaemonClient()
        var backoff = Duration.seconds(1)
        let maxBackoff = Duration.seconds(30)

        while !Task.isCancelled {
            guard host == streamHost,
                  let session = chatWorkspace.selectedTab,
                  session.id == selectedTabID,
                  session.sessionID?.nilIfBlank == sessionID else {
                return
            }

            let after = session.lastPersistedLineIndex
            DiagnosticsLogBuffer.shared.append(
                level: "debug",
                category: "session.stream",
                message: "Opening selected session stream",
                metadata: ["sessionID": sessionID, "after": String(after)]
            )
            let stream = client.streamSessionEventPages(
                host: streamHost,
                sessionID: sessionID,
                after: after
            )
            var receivedEvent = false
            do {
                for try await page in stream {
                    receivedEvent = true
                    isSelectedSessionStreamConnected = true
                    backoff = .seconds(1)
                    guard host == streamHost,
                          let currentSession = chatWorkspace.selectedTab,
                          currentSession.id == selectedTabID,
                          currentSession.sessionID?.nilIfBlank == sessionID else {
                        return
                    }
                    DiagnosticsLogBuffer.shared.append(
                        level: "debug",
                        category: "session.stream",
                        message: "Selected session stream page received",
                        metadata: [
                            "sessionID": sessionID,
                            "events": String(page.events.count),
                            "firstLine": page.firstLine.map(String.init) ?? "",
                            "lastLine": page.lastLine.map(String.init) ?? ""
                        ]
                    )
                    enqueueSessionStreamPage(page, to: currentSession, sessionID: sessionID)
                }
                isSelectedSessionStreamConnected = false
                if Task.isCancelled { return }
                try? await Task.sleep(for: backoff)
            } catch is CancellationError {
                isSelectedSessionStreamConnected = false
                return
            } catch {
                isSelectedSessionStreamConnected = false
                if Task.isCancelled { return }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    return
                }
                DiagnosticsLogBuffer.shared.append(
                    level: "warn",
                    category: "session.stream",
                    message: "Selected session stream lost",
                    metadata: ["sessionID": sessionID, "error": error.localizedDescription, "receivedEvent": String(receivedEvent)]
                )
                if !receivedEvent {
                    statusMessage = "Live session stream lost: \(error.localizedDescription). Retrying…"
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }

    private func enqueueSessionStreamPage(_ page: SessionEventsPage, to session: ChatSession, sessionID: String) {
        if session.isLoading || session.isSending {
            scheduleSelectedSessionCatchUp(after: .milliseconds(250))
            return
        }
        if pendingSelectedSessionStreamTabID != session.id || pendingSelectedSessionStreamSessionID != sessionID {
            cancelSelectedSessionStreamFlush(discardPending: true)
            pendingSelectedSessionStreamTabID = session.id
            pendingSelectedSessionStreamSessionID = sessionID
        }
        pendingSelectedSessionStreamPage = mergedSessionEventPage(pendingSelectedSessionStreamPage, appending: page)

        if (pendingSelectedSessionStreamPage?.events.count ?? 0) >= Self.selectedSessionStreamImmediateFlushEventCount {
            flushSelectedSessionStreamPage()
            return
        }

        guard selectedSessionStreamFlushTask == nil else { return }
        selectedSessionStreamFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.selectedSessionStreamCoalesceDelay)
            guard !Task.isCancelled else { return }
            self?.flushSelectedSessionStreamPage()
        }
    }

    private func flushSelectedSessionStreamPage() {
        selectedSessionStreamFlushTask?.cancel()
        selectedSessionStreamFlushTask = nil

        guard let page = pendingSelectedSessionStreamPage,
              let selectedTabID = pendingSelectedSessionStreamTabID,
              let sessionID = pendingSelectedSessionStreamSessionID else {
            pendingSelectedSessionStreamPage = nil
            pendingSelectedSessionStreamTabID = nil
            pendingSelectedSessionStreamSessionID = nil
            return
        }
        pendingSelectedSessionStreamPage = nil
        pendingSelectedSessionStreamTabID = nil
        pendingSelectedSessionStreamSessionID = nil

        guard let session = chatWorkspace.selectedTab,
              session.id == selectedTabID,
              session.sessionID?.nilIfBlank == sessionID else {
            return
        }
        if session.isLoading || session.isSending {
            scheduleSelectedSessionCatchUp(after: .milliseconds(250))
            return
        }

        guard !page.events.isEmpty else { return }

        let previousTitle = session.title
        session.appendPersistedPage(page)
        syncSidebarTitleIfNeeded(for: session, previousTitle: previousTitle)
    }

    private func cancelSelectedSessionStreamFlush(discardPending: Bool) {
        selectedSessionStreamFlushTask?.cancel()
        selectedSessionStreamFlushTask = nil
        guard discardPending else { return }
        pendingSelectedSessionStreamPage = nil
        pendingSelectedSessionStreamTabID = nil
        pendingSelectedSessionStreamSessionID = nil
    }

    private func mergedSessionEventPage(_ current: SessionEventsPage?, appending page: SessionEventsPage) -> SessionEventsPage {
        guard let current else { return page }
        let firstLine = [current.firstLine, page.firstLine].compactMap { $0 }.min()
        let lastLine = [current.lastLine, page.lastLine].compactMap { $0 }.max()
        return SessionEventsPage(
            events: current.events + page.events,
            firstLine: firstLine,
            lastLine: lastLine,
            hasMoreBefore: current.hasMoreBefore || page.hasMoreBefore,
            hasMoreAfter: current.hasMoreAfter || page.hasMoreAfter
        )
    }

    private func startSelectedSessionEventPolling() {
        selectedSessionPollingTask?.cancel()
        selectedSessionPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // When the per-session SSE stream is healthy, polling is
                // pure overhead (and risks racing with the optimistic
                // in-flight state). Keep this loop only as a slow safety
                // net for the rare case where the stream is down.
                let interval: Duration = !self.isSelectedSessionStreamConnected && self.isApplicationActive
                    ? .seconds(2)
                    : .seconds(30)
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.syncSelectedRemoteSessionDelta()
            }
        }
    }

    private func scheduleSelectedSessionCatchUp(after delay: Duration) {
        guard let selectedTabID = chatWorkspace.selectedTab?.id else { return }
        selectedSessionCatchUpTask?.cancel()
        let streamHost = host
        selectedSessionCatchUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            for _ in 0..<8 {
                guard !Task.isCancelled else { return }
                let isReady = await MainActor.run { () -> Bool? in
                    guard let self else { return nil }
                    guard self.host == streamHost,
                          let selected = self.chatWorkspace.selectedTab,
                          selected.id == selectedTabID else {
                        return nil
                    }
                    return !selected.isLoading && !selected.isSending
                }
                guard let isReady else { return }
                if isReady {
                    await self?.syncSelectedRemoteSessionDelta(force: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func syncSelectedRemoteSessionDelta(force: Bool = false) async {
        // The per-session SSE stream is the primary live path. Polling is
        // only useful when the stream is down, so skip the round-trip
        // entirely while it is healthy. Forced catch-up is used after
        // send/reload windows where SSE pages were intentionally not applied.
        guard force || !isSelectedSessionStreamConnected else { return }
        guard let session = chatWorkspace.selectedTab,
              let sessionID = session.sessionID?.nilIfBlank,
              !session.isLoading,
              !session.isSending else {
            return
        }

        let after = session.lastPersistedLineIndex
        DiagnosticsLogBuffer.shared.append(
            level: "debug",
            category: "session.catchup",
            message: "Sync selected remote session delta",
            metadata: ["sessionID": sessionID, "after": String(after), "force": String(force)]
        )
        guard after >= 0 else {
            session.loadFromDisk(force: true)
            return
        }

        let remoteAPIHost = host
        let selectedTabID = session.id
        do {
            async let deltaTask = RemoteDaemonClient().loadSessionEventPage(
                host: remoteAPIHost,
                sessionID: sessionID,
                limit: 200,
                after: after
            )
            async let runtimeTask = RemoteDaemonClient().loadSessionRuntime(
                host: remoteAPIHost,
                sessionID: sessionID
            )
            let (delta, runtime) = try await (deltaTask, runtimeTask)
            guard self.host == remoteAPIHost,
                  self.chatWorkspace.selectedTab?.id == selectedTabID else {
                return
            }
            DiagnosticsLogBuffer.shared.append(
                level: "debug",
                category: "session.catchup",
                message: "Delta loaded",
                metadata: [
                    "sessionID": sessionID,
                    "events": String(delta.events.count),
                    "firstLine": delta.firstLine.map(String.init) ?? "",
                    "lastLine": delta.lastLine.map(String.init) ?? "",
                    "hasMoreBefore": String(delta.hasMoreBefore),
                    "hasMoreAfter": String(delta.hasMoreAfter)
                ]
            )
            if let firstLine = delta.firstLine,
               !delta.events.isEmpty,
               firstLine <= after {
                DiagnosticsLogBuffer.shared.append(level: "warn", category: "session.catchup", message: "Delta overlapped visible window; forcing reload", metadata: ["sessionID": sessionID, "firstLine": String(firstLine), "after": String(after)])
                session.loadFromDisk(force: true)
                return
            }
            let previousTitle = session.title
            session.appendPersistedPage(delta)
            syncSidebarTitleIfNeeded(for: session, previousTitle: previousTitle)
            let sessionKey = runtimeSessionKey(for: session)
            session.updateRuntimeState(
                runtimeApplyingKnownModelContext(
                    runtimeApplyingPendingThinkingLevel(runtime, sessionKey: sessionKey)
                )
            )
            applyCachedAvailableModels(to: session)
        } catch {
            DiagnosticsLogBuffer.shared.append(level: "warn", category: "session.catchup", message: "Delta sync failed", metadata: ["sessionID": sessionID, "error": error.localizedDescription])
            // Best-effort background sync: keep the current transcript and
            // let catalog polling / manual reload recover.
        }
    }

    /// Outer reconnect loop. On every successful event the backoff
    /// resets, so a stable connection pays only the per-event cost. On
    /// any failure (network, auth, malformed event) we sleep with an
    /// exponentially growing delay, capped at 30s. Cancellation is
    /// observed after each iteration so a host change can tear us down
    /// promptly.
    private func runCatalogLiveUpdates(host: PiHostConfiguration) async {
        let client = RemoteDaemonClient()
        var backoff = Duration.seconds(1)
        let maxBackoff = Duration.seconds(30)

        while !Task.isCancelled {
            guard self.host == host else { return }
            let stream = client.streamCatalogSnapshots(host: host)
            var receivedEvent = false
            do {
                for try await event in stream {
                    guard self.host == host else { return }
                    receivedEvent = true
                    isCatalogStreamConnected = true
                    backoff = .seconds(1)
                    applyCatalogStreamEvent(event)
                }
                isCatalogStreamConnected = false
                if Task.isCancelled { return }
                try? await Task.sleep(for: backoff)
            } catch is CancellationError {
                isCatalogStreamConnected = false
                return
            } catch {
                isCatalogStreamConnected = false
                if Task.isCancelled { return }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    return
                }
                if !receivedEvent {
                    statusMessage = "Live catalog lost: \(error.localizedDescription). Retrying…"
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }

    /// Applies a typed event from the global SSE channel. The first event
    /// is always a full snapshot; subsequent events are small deltas.
    private func applyCatalogStreamEvent(_ event: CatalogStreamEvent) {
        switch event {
        case .snapshot(let snapshot):
            projects = snapshot.projects
            sessions = mergeSnapshotWithPendingRenames(snapshot.sessions)
            preserveOpenChatSessionSidebarEntries()
            sortCatalogState()
            if !snapshot.warnings.isEmpty {
                statusMessage = PiAppState.catalogStatusMessage(
                    sessionCount: snapshot.sessions.count,
                    warnings: snapshot.warnings
                )
            }
            repairSelectionIfNeeded()
            refreshConfigurationSummary()
        case .sessionUpdated(let summary):
            upsertCatalogSession(summary)
            syncOpenTabTitles(with: summary)
            sortCatalogState()
            repairSelectionIfNeeded()
        case .sessionRemoved(let sessionId):
            sessions.removeAll { $0.id == sessionId || $0.filePath == sessionId }
            sortCatalogState()
            repairSelectionIfNeeded()
        case .runtimeChanged(let sessionId, let runtime):
            if sessionId.isEmpty { return }
            let effectiveRuntime = runtimeApplyingKnownModelContext(runtime)
            for tab in chatWorkspace.tabs where tab.sessionID?.nilIfBlank == sessionId {
                tab.updateRuntimeState(effectiveRuntime)
            }
        case .unknown:
            break
        }
    }

    /// Builds a short status-bar message that lists the session count
    /// and any non-fatal catalog warnings, so the user actually sees
    /// "skipped 2 unreadable files" instead of getting a silently
    /// truncated catalog.
    static func catalogStatusMessage(sessionCount: Int, warnings: [String]) -> String {
        let prefix = "Loaded \(sessionCount) Pi session\(sessionCount == 1 ? "" : "s")"
        guard !warnings.isEmpty else { return prefix }
        let firstFew = warnings.prefix(3).joined(separator: " ")
        let suffix = warnings.count > 3 ? " (+ \(warnings.count - 3) more)" : ""
        return "\(prefix). \(firstFew)\(suffix)"
    }

    private func loadHost() {
        guard let data = defaults.data(forKey: hostDefaultsKey),
              let decoded = try? JSONDecoder().decode(PiHostConfiguration.self, from: data) else {
            return
        }
        host = decoded
    }

    private func saveHost() {
        guard let data = try? JSONEncoder().encode(host) else { return }
        defaults.set(data, forKey: hostDefaultsKey)
    }

    private func loadAppearance() {
        guard let data = defaults.data(forKey: appearanceDefaultsKey),
              let decoded = try? JSONDecoder().decode(AppAppearance.self, from: data) else {
            return
        }
        appearance = decoded
    }

    private func saveAppearance() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: appearanceDefaultsKey)
    }

    private func loadShortcutPreferences() {
        guard let data = defaults.data(forKey: shortcutDefaultsKey),
              let decoded = try? JSONDecoder().decode(AppShortcutPreferences.self, from: data) else {
            return
        }
        shortcutPreferences = decoded
    }

    private func saveShortcutPreferences() {
        guard let data = try? JSONEncoder().encode(shortcutPreferences) else { return }
        defaults.set(data, forKey: shortcutDefaultsKey)
    }

    private func loadModelDefaults() {
        guard let data = defaults.data(forKey: modelDefaultsKey),
              let decoded = try? JSONDecoder().decode(DefaultModelPreference.self, from: data) else {
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
        availableModelsCache = decoded.models
        availableModelsCacheLoadedAt = decoded.loadedAt
    }

    private func saveAvailableModelsCache() {
        guard !availableModelsCache.isEmpty,
              let loadedAt = availableModelsCacheLoadedAt,
              let data = try? JSONEncoder().encode(AvailableModelsCacheSnapshot(models: availableModelsCache, loadedAt: loadedAt)) else {
            defaults.removeObject(forKey: availableModelsCacheDefaultsKey)
            return
        }
        defaults.set(data, forKey: availableModelsCacheDefaultsKey)
    }

    // MARK: - Chat tab persistence

    /// Builds a snapshot of the current remote-backed open tabs and writes it
    /// to `UserDefaults`. New/fork tabs without a daemon `sessionID` are not
    /// persisted because Mac pi-app is remote-only and has no local fallback for
    /// resurrecting file-backed tabs.
    func savePersistedChatTabs() {
        let tabs = chatWorkspace.tabs.compactMap { session -> PersistedChatTab? in
            guard Self.isPersistedRemoteTab(key: session.key, sessionID: session.sessionID) else { return nil }
            return PersistedChatTab(
                key: session.key,
                title: session.title,
                sessionID: session.sessionID
            )
        }
        // Only persist the selected key if the selected tab is also
        // remote-backed. A `new:<UUID>` selection would never be
        // resolvable on the next launch, so it is intentionally dropped.
        let selectedKey: String? = {
            guard let selected = chatWorkspace.selectedTab,
                  Self.isPersistedRemoteTab(key: selected.key, sessionID: selected.sessionID) else { return nil }
            return selected.key
        }()
        let snapshot = PersistedChatTabsSnapshot(
            hostFingerprint: host.persistenceFingerprint,
            tabs: tabs,
            selectedTabKey: selectedKey
        )
        chatTabPersistence.save(snapshot)
    }

    /// Debounces `savePersistedChatTabs` so a burst of mutations during
    /// streaming (e.g. successive `bindToSession` calls) collapses into
    /// a single write.
    func schedulePersistedChatTabsSave() {
        chatTabsSaveTask?.cancel()
        chatTabsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.savePersistedChatTabs()
            }
        }
    }

    /// Reopens remote-backed tabs and restores the selected tab from the
    /// persisted snapshot. Legacy file-backed tabs are ignored because Mac
    /// pi-app no longer reads local session files.
    func restorePersistedChatTabs() {
        guard let snapshot = chatTabPersistence.load() else { return }
        // Different host: keep the snapshot on disk (it will be
        // overwritten on the next save) but do not reopen any tabs.
        guard snapshot.hostFingerprint == host.persistenceFingerprint else { return }

        let selectedKey = snapshot.selectedTabKey

        for tab in snapshot.tabs {
            guard Self.isPersistedRemoteTab(key: tab.key, sessionID: tab.sessionID) else { continue }
            let shouldLoadImmediately = tab.key == selectedKey
            let loader = tab.sessionID.flatMap { remoteEventLoader(sessionID: $0) }
            let historyLoader = tab.sessionID.flatMap { remoteHistoryPageLoader(sessionID: $0) }
            chatWorkspace.openOrSelectTab(
                key: tab.key,
                title: tab.title,
                sessionID: tab.sessionID,
                sessionPath: nil,
                eventLoader: loader,
                historyPageLoader: historyLoader,
                autoLoad: shouldLoadImmediately
            )
        }

        if let selectedKey,
           let tab = chatWorkspace.tabs.first(where: { $0.key == selectedKey }) {
            chatWorkspace.select(tab)
        }
    }

    /// `true` for tabs that can be restored through `pi-appd` alone.
    private static func isPersistedRemoteTab(key: String, sessionID: String?) -> Bool {
        guard !key.isEmpty,
              sessionID?.nilIfBlank != nil else { return false }
        return !isTransientTabKey(key)
    }

    private static func isTransientTabKey(_ key: String) -> Bool {
        key.hasPrefix("new:") || key.hasPrefix("fork:")
    }

    private func openPath(_ path: String?) {
        guard let path, pathExists(path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openFirstOrReveal(paths: [String], fallback: String) {
        if paths.count == 1 {
            openPath(paths.first)
        } else {
            revealPath(paths.first ?? fallback)
        }
    }

    private func revealPath(_ path: String?) {
        guard let path, pathExists(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func sourceTaggedAppPrompt(_ text: String, session: ChatSession) -> String {
        if text.range(of: #"^\[source:[^\]]+\]"#, options: .regularExpression) != nil {
            return text
        }
        let runtime = session.runtimeState
        let model = runtime?.modelID?.nilIfBlank ?? session.launchRequest?.initialModelID ?? "unknown"
        let thinking = runtime?.thinkingLevel.nilIfBlank ?? session.launchRequest?.initialThinkingLevel ?? "off"
        let fields = [
            "source:pi-macos-app",
            "type=text",
            "session=\"\(Self.sourceTagValue(session.title))\"",
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

    private func promoteSidebarSession(for session: ChatSession, fallbackAliases: [String]) {
        let aliases = Set(sessionAliases(for: session, fallback: fallbackAliases))
        if let existing = sessions.first(where: { !aliases.isDisjoint(with: Set(sessionAliases(for: $0))) }) {
            if chatWorkspace.selectedTab?.id == session.id {
                selection = .session(existing.id)
            }
            sortCatalogState()
        } else {
            upsertSidebarSession(for: session, previousAliases: fallbackAliases)
        }
    }

    private func removeOptimisticSidebarSessionIfNeeded(matching aliases: [String]) {
        let optimisticAliases = aliases.filter(Self.isTransientTabKey)
        guard !optimisticAliases.isEmpty else { return }

        var affectedProjectIDs = Set<String>()
        sessions.removeAll { summary in
            let matches = !Set(sessionAliases(for: summary)).isDisjoint(with: Set(optimisticAliases))
            if matches {
                affectedProjectIDs.insert(summary.projectID)
            }
            return matches
        }
        for projectID in affectedProjectIDs {
            reconcileSidebarProject(projectID)
        }
    }

    private func preserveOpenChatSessionSidebarEntries() {
        for session in chatWorkspace.tabs {
            let aliases = Set(sessionAliases(for: session))
            let isSelected = chatWorkspace.selectedTab?.id == session.id
            if let existing = sessions.first(where: { !aliases.isDisjoint(with: Set(sessionAliases(for: $0))) }) {
                session.rename(to: existing.title)
                if isSelected {
                    selection = .session(existing.id)
                }
                continue
            }
            let shouldPreserve = session.isSending || session.launchRequest != nil || isSelected
            guard shouldPreserve else { continue }
            upsertSidebarSession(for: session)
        }
    }

    private func syncSidebarTitleIfNeeded(for session: ChatSession, previousTitle: String) {
        guard session.title != previousTitle else { return }
        let aliases = Set(sessionAliases(for: session))
        if let existing = sessions.first(where: { !aliases.isDisjoint(with: Set(sessionAliases(for: $0))) }) {
            applyRenamedSession(existing, title: session.title)
        } else {
            upsertSidebarSession(for: session)
        }
        schedulePersistedChatTabsSave()
    }

    private func upsertSidebarSession(
        for session: ChatSession,
        previousAliases: [String] = [],
        fallbackWorkingDirectory: String? = nil
    ) {
        guard let summary = sidebarSessionSummary(
            for: session,
            previousAliases: previousAliases,
            fallbackWorkingDirectory: fallbackWorkingDirectory
        ) else {
            return
        }

        let matchingAliases = Set(previousAliases + sessionAliases(for: session))
        let previousProjectID = sessions.first(where: {
            !matchingAliases.isDisjoint(with: Set(sessionAliases(for: $0)))
        })?.projectID

        if let index = sessions.firstIndex(where: { !matchingAliases.isDisjoint(with: Set(sessionAliases(for: $0))) }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }

        if chatWorkspace.selectedTab?.id == session.id {
            selection = .session(summary.id)
        }

        reconcileSidebarProject(summary.projectID)
        if let previousProjectID, previousProjectID != summary.projectID {
            reconcileSidebarProject(previousProjectID)
        }
    }

    private func sidebarSessionSummary(
        for session: ChatSession,
        previousAliases: [String] = [],
        fallbackWorkingDirectory: String? = nil
    ) -> PiSessionSummary? {
        let workingDirectory = fallbackWorkingDirectory?.nilIfBlank
            ?? session.launchRequest?.workingDirectory?.nilIfBlank
            ?? selectedWorkingDirectory?.nilIfBlank
        let filePath = session.sessionPath?.nilIfBlank
            ?? session.sessionID?.nilIfBlank
            ?? previousAliases.first(where: { !$0.isEmpty })
            ?? session.key.nilIfBlank
        guard let filePath else { return nil }

        let id = session.sessionID?.nilIfBlank ?? filePath
        let aliases = uniqueAliases([session.sessionID, session.sessionPath, session.key] + previousAliases.map(Optional.some))
        let modifiedAt = aliases.compactMap { sessionActivityOverrides[$0] }.max() ?? Date()
        let projectID = sidebarProjectID(for: workingDirectory)

        return PiSessionSummary(
            id: id,
            filePath: filePath,
            projectID: projectID,
            title: session.title,
            workingDirectory: workingDirectory,
            messageCount: 0,
            modifiedAt: modifiedAt,
            displayName: nil,
            parentSession: nil,
            branchCount: 0,
            labelCount: 0,
            branchSummaryCount: 0,
            latestModel: session.runtimeState?.modelDisplayName.nilIfBlank,
            isGenerating: session.isSending
        )
    }

    private func sidebarProjectID(for workingDirectory: String?) -> String {
        guard let workingDirectory = workingDirectory?.nilIfBlank else {
            return activeProject?.id ?? "sessions"
        }
        let standardizedPath = (workingDirectory as NSString).standardizingPath
        let components = URL(fileURLWithPath: standardizedPath)
            .pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        guard !components.isEmpty else { return "--root--" }
        return "--\(components.joined(separator: "-"))--"
    }

    private func reconcileSidebarProject(_ projectID: String) {
        let projectSessions = sessions.filter { $0.projectID == projectID }
        guard !projectSessions.isEmpty else {
            projects.removeAll { $0.id == projectID }
            return
        }

        let workingDirectory = projectSessions.compactMap(\.workingDirectory).first
        let title = projects.first(where: { $0.id == projectID })?.title
            ?? workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Sessions"
        let lastActivity = projectSessions
            .map { effectiveLastActivity(for: $0) }
            .max()

        let updated = PiProject(
            id: projectID,
            title: title,
            workingDirectory: workingDirectory,
            sessionDirectory: projectID,
            sessionCount: projectSessions.count,
            lastActivity: lastActivity
        )

        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index] = updated
        } else {
            projects.append(updated)
        }
        sortCatalogState()
    }

    /// Returns `snapshot` with any session that has a pending optimistic rename
    /// replaced by the locally retained summary. This keeps the sidebar title
    /// stable across in-flight `set_session_name` RPCs, which can take minutes
    /// to commit on the daemon side.
    private func mergeSnapshotWithPendingRenames(_ snapshot: [PiSessionSummary]) -> [PiSessionSummary] {
        guard !pendingRenames.isEmpty else { return snapshot }
        var pinned: [String: PiSessionSummary] = [:]
        for session in sessions where pendingRenames.contains(session.id) {
            pinned[session.id] = session
        }
        guard !pinned.isEmpty else { return snapshot }
        return snapshot.map { snap in pinned[snap.id] ?? snap }
    }

    private func upsertCatalogSession(_ summary: PiSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == summary.id || $0.filePath == summary.filePath }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }
    }

    private func applyRenamedSession(_ session: PiSessionSummary, title: String) {
        let renamed = PiSessionSummary(
            id: session.id,
            filePath: session.filePath,
            projectID: session.projectID,
            title: title,
            workingDirectory: session.workingDirectory,
            messageCount: session.messageCount,
            modifiedAt: session.modifiedAt,
            displayName: title,
            parentSession: session.parentSession,
            branchCount: session.branchCount,
            labelCount: session.labelCount,
            branchSummaryCount: session.branchSummaryCount,
            latestModel: session.latestModel,
            isGenerating: session.isGenerating
        )
        upsertCatalogSession(renamed)
        syncOpenTabTitles(with: renamed)
        sortCatalogState()
    }

    private func syncOpenTabTitles(with summary: PiSessionSummary) {
        let aliases = Set(sessionAliases(for: summary))
        for tab in chatWorkspace.tabs where !aliases.isDisjoint(with: Set(sessionAliases(for: tab))) {
            tab.rename(to: summary.title)
        }
    }

    private func sessionAliases(for session: PiSessionSummary) -> [String] {
        uniqueAliases([session.id, session.filePath])
    }

    private func sessionAliases(for session: ChatSession, fallback: [String] = []) -> [String] {
        uniqueAliases([session.sessionID, session.sessionPath, session.key] + fallback.map(Optional.some))
    }

    private func uniqueAliases(_ aliases: [String?]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawAlias in aliases {
            guard let rawAlias, let alias = rawAlias.nilIfBlank else { continue }
            if seen.insert(alias).inserted {
                result.append(alias)
            }
        }
        return result
    }

    private func markSessionActive(_ aliases: [String], at date: Date = Date()) {
        for alias in aliases {
            sessionActivityOverrides[alias] = date
        }
        sortCatalogState()
    }

    private func setSessionSending(_ isSending: Bool, aliases: [String]) {
        guard !aliases.isEmpty else { return }
        if isSending {
            sendingSessionKeys.formUnion(aliases)
        } else {
            sendingSessionKeys.subtract(aliases)
        }
    }

    private func clearUnread(aliases: [String]) {
        unreadSessionKeys.subtract(aliases)
    }

    private func markUnread(aliases: [String]) {
        unreadSessionKeys.formUnion(aliases)
    }

    private func markSessionRead(_ session: PiSessionSummary) {
        clearUnread(aliases: sessionAliases(for: session))
    }

    private func clearSessionState(for session: PiSessionSummary) {
        let aliases = sessionAliases(for: session)
        sendingSessionKeys.subtract(aliases)
        unreadSessionKeys.subtract(aliases)
        for alias in aliases {
            sessionActivityOverrides.removeValue(forKey: alias)
        }
    }

    private func migrateSessionState(from oldAliases: [String], to newAliases: [String]) {
        guard !oldAliases.isEmpty, !newAliases.isEmpty else { return }
        let lastActivity = oldAliases.compactMap { sessionActivityOverrides[$0] }.max()
        let wasSending = !sendingSessionKeys.isDisjoint(with: Set(oldAliases))
        let wasUnread = !unreadSessionKeys.isDisjoint(with: Set(oldAliases))

        if let lastActivity {
            markSessionActive(newAliases, at: lastActivity)
        }
        if wasSending {
            sendingSessionKeys.formUnion(newAliases)
        }
        if wasUnread {
            unreadSessionKeys.formUnion(newAliases)
        }
    }

    private func completeSend(for session: ChatSession, fallbackAliases: [String]) {
        let aliases = sessionAliases(for: session, fallback: fallbackAliases)
        setSessionSending(false, aliases: aliases)
        markSessionActive(aliases)
        if !isCurrentlyViewingSession(aliases: aliases) {
            markUnread(aliases: aliases)
        } else {
            clearUnread(aliases: aliases)
        }
    }

    private func isCurrentlyViewingSession(aliases: [String]) -> Bool {
        let targetAliases = Set(aliases)
        if let selectedSession,
           !targetAliases.isDisjoint(with: Set(sessionAliases(for: selectedSession))) {
            return true
        }
        if let selectedTab = chatWorkspace.selectedTab,
           !targetAliases.isDisjoint(with: Set(sessionAliases(for: selectedTab))) {
            return true
        }
        return false
    }

    private func uploadAttachmentsIfNeeded(_ attachments: [ChatAttachment]) async throws -> [UploadedAttachmentReference] {
        guard !attachments.isEmpty else { return [] }
        var uploaded: [UploadedAttachmentReference] = []
        let client = RemoteDaemonClient()
        for attachment in attachments {
            uploaded.append(try await client.uploadAttachment(host: host, attachment: attachment))
        }
        return uploaded
    }
}

private extension PiLaunchRequest {
    mutating func applyDefaults(from runtime: SessionRuntimeState) {
        if !hasExplicitInitialModel {
            if let provider = runtime.provider?.nilIfBlank,
               let modelID = runtime.modelID?.nilIfBlank {
                initialModelProvider = provider
                initialModelID = modelID
            } else {
                initialModelProvider = nil
                initialModelID = nil
            }
        }
        if !hasExplicitInitialThinkingLevel {
            initialThinkingLevel = runtime.thinkingLevel.nilIfBlank
        }
    }
}
