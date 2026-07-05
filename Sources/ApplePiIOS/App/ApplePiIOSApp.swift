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
    @Published private(set) var projects: [PiProject] = []
    @Published private(set) var sessions: [PiSessionSummary] = []
    @Published private(set) var selectedSession: PiSessionSummary?
    @Published private(set) var selectedEvents: [SessionEvent] = []
    @Published private(set) var statusMessage = "Configure pi-appd to begin."
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isLoadingSession = false
    @Published private(set) var isSending = false
    @Published var draft = ""

    private let defaults: UserDefaults
    private let hostDefaultsKey = "ApplePiIOS.host"
    private var catalogStreamTask: Task<Void, Never>?
    private var selectedSessionStreamTask: Task<Void, Never>?
    private var selectedSessionGeneration = UUID()
    private var selectedPersistedEventIDs = Set<String>()
    private var selectedLastLine: Int?

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

    func loadInitialCatalogIfConfigured() async {
        guard isConfigured else { return }
        await reloadCatalog()
        startCatalogStream()
        await catchUpSelectedSession(reason: "initial load")
        startSelectedSessionStreamIfPossible()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard isConfigured else { return }
            startCatalogStream()
            Task {
                await reloadCatalog(quietly: true)
                await catchUpSelectedSession(reason: "foreground")
                startSelectedSessionStreamIfPossible()
            }
        case .background:
            stopSelectedSessionStream()
        case .inactive:
            break
        @unknown default:
            break
        }
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
        guard isConfigured else { return }
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

    func selectSession(_ session: PiSessionSummary) async {
        selectedSession = session
        resetSelectedTranscript()
        await reloadSelectedSession()
    }

    func startNewSession() {
        selectedSession = nil
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
        } catch {
            guard self.selectedSession?.id == selectedSession.id else { return }
            statusMessage = error.localizedDescription
            startSelectedSessionStreamIfPossible()
        }
    }

    func sendDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        isSending = true
        defer { isSending = false }

        let host = host
        do {
            if let selectedSession {
                try await RemoteDaemonClient().streamSend(host: host, sessionID: selectedSession.id, prompt: prompt) { event in
                    await self.handleTurnStreamEvent(event)
                }
            } else {
                resetSelectedTranscript()
                let request = PiLaunchRequest(workingDirectory: host.defaultWorkingDirectory)
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
        case .runtimeChanged, .unknown:
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
        guard isConfigured,
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
        guard isConfigured,
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
        selectedEvents = page.events
        selectedPersistedEventIDs = Set(page.events.map(\.id))
        selectedLastLine = page.lastLine ?? page.events.map(\.lineIndex).max()
        sortSelectedEventsForDisplay()
    }

    private func mergePersistedPage(_ page: SessionEventsPage) {
        guard !page.events.isEmpty || page.lastLine != nil else { return }
        for event in page.events {
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
        for event in events {
            guard !selectedPersistedEventIDs.contains(event.id) else { continue }
            upsertSelectedEvent(event, allowPersistedToWin: false)
        }
        sortSelectedEventsForDisplay()
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
