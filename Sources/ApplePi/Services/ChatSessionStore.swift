import Foundation
import SwiftUI
import ApplePiCore
import ApplePiRemote

/// One Pi session that the user has open in a tab. The read-only MVP loads
/// the underlying `.jsonl` file once and exposes the events to the chat
/// view; live sends add transient user/assistant events while the backing
/// process or remote daemon streams updates.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id = UUID()
    var key: String
    @Published var title: String
    @Published private(set) var events: [SessionEvent] = []
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadError: String?
    @Published private(set) var isSending: Bool = false
    @Published private(set) var streamRevision: Int = 0
    @Published private(set) var historyRevision: Int = 0
    @Published private(set) var runtimeState: SessionRuntimeState?
    @Published private(set) var availableModels: [PiModelOption] = []
    @Published private(set) var hasEarlierHistory: Bool = false
    @Published private(set) var isLoadingEarlierHistory: Bool = false
    @Published private(set) var isAwaitingTurnCommit: Bool = false
    @Published private(set) var canAcceptSteering: Bool = false
    @Published var draftText: String = ""
    @Published var draftHeight: CGFloat = 30

    /// Path to the on-disk jsonl, if this session is backed by a file. For
    /// brand-new sessions the path is assigned once the first turn creates it.
    private(set) var sessionPath: String?
    private(set) var sessionID: String?
    private(set) var launchRequest: PiLaunchRequest?
    private var eventLoader: (@Sendable () async throws -> SessionEventsPage)?
    private var historyPageLoader: (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)?
    private var hasLoadedOnce = false
    private var lastLoadedModificationDate: Date?
    private var loadTask: Task<Void, Never>?
    private var sendGeneration: Int = 0
    private var pendingSendCompletionGeneration: Int?
    private var needsReloadAfterCurrentLoad = false
    private var forceReloadAfterCurrentLoad = false
    private var pendingHistoryAnchorEventID: String?
    /// The in-flight send task, if any. `PiAppState.sendMessage`
    /// assigns the task it spawns so the store can cancel it when
    /// the tab is closed. The task body clears the reference on
    /// completion (success, error, or cancellation). The setter is
    /// intentionally `internal` rather than `private(set)` because
    /// the only legitimate writer lives in a different file
    /// (`PiAppState`).
    var sendTask: Task<Void, Never>?

    private var persistedEvents: [SessionEvent] = []
    private var retainedTransientEvents: [SessionEvent] = []
    private var transientUserEvent: SessionEvent?
    private var transientAssistantEvent: SessionEvent?
    private var transientStreamEvents: [SessionEvent] = []
    private var didAbortCurrentSend = false

    var lastPersistedLineIndex: Int {
        persistedEvents.last?.lineIndex ?? -1
    }

    var firstPersistedLineIndex: Int {
        persistedEvents.first?.lineIndex ?? -1
    }

    var pendingHistoryAnchorID: String? {
        pendingHistoryAnchorEventID
    }

    init(
        key: String,
        title: String,
        sessionID: String? = nil,
        sessionPath: String? = nil,
        launchRequest: PiLaunchRequest? = nil,
        eventLoader: (@Sendable () async throws -> SessionEventsPage)? = nil,
        historyPageLoader: (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? = nil
    ) {
        self.key = key
        self.title = title
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.launchRequest = launchRequest
        self.eventLoader = eventLoader
        self.historyPageLoader = historyPageLoader
    }

    var canSend: Bool {
        !isSending && !isLoading
    }

    var currentSendGeneration: Int {
        sendGeneration
    }

    /// True while a send task is associated with this session. The
    /// store uses this to decide whether closing the tab needs to
    /// cancel work in flight.
    var hasActiveSend: Bool { sendTask != nil }

    var hasAbortedCurrentSend: Bool { didAbortCurrentSend }

    /// Cancel the active send task, if any, and drop the reference.
    /// Safe to call from any state, including when no task is running.
    /// The task body still runs to completion but its cancellation
    /// handler is responsible for tearing down the underlying process
    /// or HTTP stream.
    func cancelSend() {
        if let task = sendTask {
            task.cancel()
        }
        sendTask = nil
    }

    func abortSend() {
        didAbortCurrentSend = true
        // Do not cancel or mark the active stream as non-steerable here.
        // Until output_complete arrives, this is still the current live RPC
        // turn; starting a new send would reset transient transcript state and
        // make pre-abort messages appear to vanish. Keep the stream steerable
        // so any next composer submit before stream close goes through the
        // existing run instead of racing it.
        statusMessage = "Aborting..."
        appendAbortCommandIfNeeded()
        rebuildEvents()
    }

    func bindToSession(
        key: String? = nil,
        title: String? = nil,
        sessionID: String?,
        sessionPath: String?,
        eventLoader: (@Sendable () async throws -> SessionEventsPage)?,
        historyPageLoader: (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)?
    ) {
        if let key {
            self.key = key
        }
        if let title {
            self.title = title
        }
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.eventLoader = eventLoader
        self.historyPageLoader = historyPageLoader
        self.launchRequest = nil
        self.hasEarlierHistory = false
        self.isLoadingEarlierHistory = false
        self.isAwaitingTurnCommit = false
        self.canAcceptSteering = false
        self.pendingHistoryAnchorEventID = nil
    }

    func updateLaunchRequest(_ launchRequest: PiLaunchRequest?) {
        self.launchRequest = launchRequest
    }

    func updateRuntimeState(_ runtimeState: SessionRuntimeState?) {
        self.runtimeState = runtimeState
    }

    func updateAvailableModels(_ availableModels: [PiModelOption]) {
        self.availableModels = availableModels
    }

    func beginSending(prompt: String, attachments: [ChatAttachment] = []) {
        loadError = nil
        sendGeneration &+= 1
        didAbortCurrentSend = false
        pendingSendCompletionGeneration = nil
        isSending = true
        isAwaitingTurnCommit = false
        canAcceptSteering = true
        statusMessage = "Thinking..."
        retainCurrentTransientTranscript()

        var content: [ContentBlock] = attachments.map { attachment in
            switch attachment.kind {
            case .image:
                return .image(path: attachment.filePath, mime: attachment.mimeType)
            case .file:
                return .text(
                    "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Binary file attached: \(attachment.displayName.xmlEscapedForPrompt)]</file>"
                )
            case .audio:
                return .text(
                    "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Audio attachment: \(attachment.displayName.xmlEscapedForPrompt)]</file>"
                )
            }
        }
        if !prompt.isEmpty {
            content.append(.text(prompt))
        }

        transientUserEvent = .message(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: content,
                model: nil,
                timestamp: Date(),
                parentId: nil
            ),
            lineIndex: Self.transientUserLineIndex
        )
        transientAssistantEvent = .message(
            Message(
                id: UUID().uuidString,
                role: .assistant,
                content: [],
                model: nil,
                timestamp: nil,
                parentId: nil
            ),
            lineIndex: Self.transientAssistantLineIndex
        )
        transientStreamEvents = []
        rebuildEvents()
    }

    @discardableResult
    func applyStreamingEvents(_ events: [SessionEvent], isFinal: Bool) -> Bool {
        let didUpdateTitle = updateTitleFromSessionMetadata(in: events)
        var nextStreamEvents = transientStreamEvents

        for event in events {
            switch event {
            case .message(let message, _):
                guard message.role == .assistant else { continue }
                let transientEvent = SessionEvent.message(
                    message,
                    lineIndex: nextTransientLineIndex(for: nextStreamEvents.count)
                )
                upsertTransientStreamEvent(transientEvent, into: &nextStreamEvents)
            case .toolCall(let call, _):
                let transientEvent = SessionEvent.toolCall(call, lineIndex: nextTransientLineIndex(for: nextStreamEvents.count))
                upsertTransientStreamEvent(transientEvent, into: &nextStreamEvents)
            case .toolResult(let result, _):
                let transientEvent = SessionEvent.toolResult(result, lineIndex: nextTransientLineIndex(for: nextStreamEvents.count))
                upsertTransientStreamEvent(transientEvent, into: &nextStreamEvents)
            case .meta, .other:
                continue
            }
        }

        if !nextStreamEvents.isEmpty {
            transientAssistantEvent = nil
        }
        if isFinal {
            isAwaitingTurnCommit = true
        } else if !events.isEmpty {
            isAwaitingTurnCommit = false
        }
        transientStreamEvents = nextStreamEvents
        statusMessage = isFinal ? "Finishing..." : "Streaming response..."
        rebuildEvents()
        return didUpdateTitle
    }

    func finishSendingAndReload() {
        pendingSendCompletionGeneration = sendGeneration
        // The active RPC/HTTP turn is over once this method is called. Keep
        // only the lightweight "awaiting commit" flag while the persisted
        // JSONL catch-up reloads, so the app no longer looks like Pi is still
        // generating and the composer can accept the next prompt immediately.
        isSending = false
        isAwaitingTurnCommit = true
        canAcceptSteering = false
        statusMessage = "Refreshing session..."
        rebuildEvents()
        loadFromDisk(force: true)
    }

    /// The active RPC/HTTP turn is already closed, but the UI may still be
    /// waiting for a final reload/catch-up. Let the composer start the next
    /// user message without being blocked by that bookkeeping state.
    func finishFinalizingForFollowUp() {
        guard !canAcceptSteering, (isSending || isAwaitingTurnCommit || sendTask != nil) else { return }
        pendingSendCompletionGeneration = nil
        isSending = false
        isAwaitingTurnCommit = false
        canAcceptSteering = false
        statusMessage = ""
        rebuildEvents()
    }

    func appendSteeringPrompt(_ prompt: String, attachments: [ChatAttachment] = []) {
        var content: [ContentBlock] = attachments.map { attachment in
            switch attachment.kind {
            case .image:
                return .image(path: attachment.filePath, mime: attachment.mimeType)
            case .file:
                return .text("<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Binary file attached: \(attachment.displayName.xmlEscapedForPrompt)]</file>")
            case .audio:
                return .text("<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Audio attachment: \(attachment.displayName.xmlEscapedForPrompt)]</file>")
            }
        }
        if !prompt.isEmpty {
            content.append(.text(prompt))
        }
        let event = SessionEvent.message(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: content,
                model: nil,
                timestamp: Date(),
                parentId: nil
            ),
            lineIndex: nextTransientLineIndex(for: transientStreamEvents.count)
        )
        upsertTransientStreamEvent(event, into: &transientStreamEvents)
        statusMessage = "Steering..."
        rebuildEvents()
    }

    private func appendAbortCommandIfNeeded() {
        let alreadyVisible = transientStreamEvents.contains { event in
            guard case .message(let message, _) = event,
                  message.role == .user else { return false }
            return message.content.contains { block in
                if case .text(let text) = block {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines) == "/abort"
                }
                return false
            }
        }
        guard !alreadyVisible else { return }
        let event = SessionEvent.message(
            Message(
                id: UUID().uuidString,
                role: .user,
                content: [.text("/abort")],
                model: nil,
                timestamp: Date(),
                parentId: nil
            ),
            lineIndex: nextTransientLineIndex(for: transientStreamEvents.count)
        )
        transientStreamEvents.append(event)
    }

    /// Mark the current send as cancelled without showing an error to
    /// the user. Called from `PiAppState.sendMessage` when the task
    /// body observes `CancellationError` (e.g. the tab was closed
    /// mid-send). Freezes already-visible transient transcript rows before
    /// clearing the current send slot, so text that appeared in chat never
    /// disappears just because the transport was cancelled or superseded.
    func finishSendingCancelled() {
        if didAbortCurrentSend {
            finishSendingAborted()
            return
        }
        pendingSendCompletionGeneration = nil
        isSending = false
        isAwaitingTurnCommit = false
        canAcceptSteering = false
        statusMessage = ""
        retainCurrentTransientTranscript()
        transientUserEvent = nil
        transientAssistantEvent = nil
        transientStreamEvents = []
        rebuildEvents()
    }

    func recordAbortAcknowledged() {
        didAbortCurrentSend = true
        statusMessage = "Aborted"
        appendAbortEventIfNeeded()
        rebuildEvents()
    }

    func finishSendingAborted() {
        pendingSendCompletionGeneration = nil
        isSending = false
        isAwaitingTurnCommit = false
        canAcceptSteering = false
        statusMessage = "Aborted"
        appendAbortEventIfNeeded()
        rebuildEvents()
    }

    private func appendAbortEventIfNeeded() {
        if !transientStreamEvents.contains(where: { event in
            if case .other(let type, _) = event { return type == "abort" }
            return false
        }) {
            transientStreamEvents.append(.other(type: "abort", lineIndex: nextTransientLineIndex(for: transientStreamEvents.count)))
        }
    }

    func finishSendingWithError(_ message: String) {
        pendingSendCompletionGeneration = nil
        isSending = false
        isAwaitingTurnCommit = false
        canAcceptSteering = false
        loadError = message
        statusMessage = message
        retainCurrentTransientTranscript()
        transientUserEvent = nil
        transientAssistantEvent = nil
        transientStreamEvents = []
        rebuildEvents()
    }

    func appendPersistedEvents(_ newEvents: [SessionEvent]) {
        appendPersistedPage(SessionEventsPage.fromEvents(newEvents))
    }

    @discardableResult
    func appendPersistedPage(_ page: SessionEventsPage) -> Bool {
        let didUpdateTitle = updateTitleFromSessionMetadata(in: page.events)
        let filtered = page.events.filter { $0.lineIndex > lastPersistedLineIndex }
        if !filtered.isEmpty {
            persistedEvents.append(contentsOf: filtered)
            reconcileTransientEvents(with: persistedEvents)
            rebuildEvents()
            statusMessage = "\(persistedEvents.count) events"
        }
        if page.hasMoreBefore {
            hasEarlierHistory = true
        }
        return didUpdateTitle
    }

    func loadEarlierHistory(limit: Int = 60) {
        guard let historyPageLoader,
              !isLoadingEarlierHistory,
              !isLoading else { return }

        let before = firstPersistedLineIndex
        guard before > 0 else {
            hasEarlierHistory = false
            return
        }

        let anchorEventID = persistedEvents.first?.id
        isLoadingEarlierHistory = true
        loadError = nil

        Task { [weak self] in
            do {
                let page = try await historyPageLoader(before, limit)
                await MainActor.run {
                    guard let self else { return }
                    defer { self.isLoadingEarlierHistory = false }
                    guard self.firstPersistedLineIndex == before else { return }
                    self.prependPersistedPage(page, anchorEventID: anchorEventID)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingEarlierHistory = false
                    self.loadError = error.localizedDescription
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func consumePendingHistoryAnchorID() -> String? {
        defer { pendingHistoryAnchorEventID = nil }
        return pendingHistoryAnchorEventID
    }

    /// Reload the session from disk or remote API. Safe to call multiple
    /// times; replaces the current persisted event list.
    func loadFromDisk(force: Bool = false) {
        guard !isLoading else {
            needsReloadAfterCurrentLoad = true
            forceReloadAfterCurrentLoad = forceReloadAfterCurrentLoad || force
            return
        }

        let sessionPath = self.sessionPath
        let eventLoader = self.eventLoader
        let previousLoadedOnce = hasLoadedOnce
        let previousModificationDate = lastLoadedModificationDate
        let completionGeneration = pendingSendCompletionGeneration

        pendingHistoryAnchorEventID = nil

        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                await SessionLoadWorker.load(
                    sessionPath: sessionPath,
                    eventLoader: eventLoader,
                    force: force,
                    previousLoadedOnce: previousLoadedOnce,
                    previousModificationDate: previousModificationDate
                )
            }.value

            guard let self else { return }
            switch outcome {
            case .skipped:
                finishLoad(completionGeneration: completionGeneration)
            case .notBackedByFile:
                statusMessage = "Session is not backed by a file yet."
                finishLoad(completionGeneration: completionGeneration)
            case .loaded(let page, let modificationDate):
                persistedEvents = reloadedPersistedEvents(from: page)
                hasEarlierHistory = hasEarlierHistoryAvailable(afterReloading: page)
                updateTitleFromSessionMetadata(in: page.events)
                reconcileTransientEvents(with: persistedEvents)
                rebuildEvents()
                statusMessage = page.events.isEmpty ? "Session is empty." : "\(page.events.count) events"
                hasLoadedOnce = true
                lastLoadedModificationDate = modificationDate
                finishLoad(completionGeneration: completionGeneration)
            case .failed(let message):
                loadError = message
                statusMessage = "Failed to read session: \(message)"
                finishLoad(completionGeneration: completionGeneration)
            }
        }
    }

    private func finishLoad(completionGeneration: Int?) {
        isLoading = false
        completeSendReloadIfNeeded(for: completionGeneration)
        loadTask = nil

        guard needsReloadAfterCurrentLoad else { return }
        let force = forceReloadAfterCurrentLoad
        needsReloadAfterCurrentLoad = false
        forceReloadAfterCurrentLoad = false
        loadFromDisk(force: force)
    }

    /// Replace the title (e.g. when the user renames the tab).
    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
    }

    @discardableResult
    private func updateTitleFromSessionMetadata(in events: [SessionEvent]) -> Bool {
        for event in events.reversed() {
            guard case .meta(let meta, _) = event,
                  let displayName = meta.displayName?.nilIfBlank,
                  displayName != title else {
                continue
            }
            title = displayName
            return true
        }
        return false
    }

    private func rebuildEvents() {
        events = persistedEvents + visibleTransientEvents
        streamRevision &+= 1
    }

    private func reloadedPersistedEvents(from page: SessionEventsPage) -> [SessionEvent] {
        guard hasLoadedOnce, page.hasMoreBefore || page.hasMoreAfter else {
            return page.events
        }

        // Remote reloads usually fetch only the latest page. If older rows were
        // already visible, replacing the transcript with just that page makes
        // them appear to vanish. Keep the loaded window and merge in the fresh
        // page. Both sides are already ordered by JSONL line, so a linear merge
        // avoids sorting the whole transcript on every reload.
        return mergePersistedEvents(persistedEvents, withFreshPage: page.events)
    }

    private func mergePersistedEvents(_ existing: [SessionEvent], withFreshPage fresh: [SessionEvent]) -> [SessionEvent] {
        guard !existing.isEmpty else { return fresh }
        guard !fresh.isEmpty else { return existing }

        let freshIDs = Set(fresh.map(\.id))
        let retained = existing.filter { !freshIDs.contains($0.id) }
        var merged: [SessionEvent] = []
        merged.reserveCapacity(retained.count + fresh.count)
        var left = 0
        var right = 0
        while left < retained.count || right < fresh.count {
            if right >= fresh.count {
                merged.append(retained[left])
                left += 1
            } else if left >= retained.count {
                merged.append(fresh[right])
                right += 1
            } else if retained[left].lineIndex <= fresh[right].lineIndex {
                merged.append(retained[left])
                left += 1
            } else {
                merged.append(fresh[right])
                right += 1
            }
        }
        return merged
    }

    private func hasEarlierHistoryAvailable(afterReloading page: SessionEventsPage) -> Bool {
        guard hasLoadedOnce, page.hasMoreBefore || page.hasMoreAfter else {
            return page.hasMoreBefore
        }
        guard let firstLine = persistedEvents.first?.lineIndex else {
            return page.hasMoreBefore
        }
        return firstLine > 0
    }

    private var visibleTransientEvents: [SessionEvent] {
        (retainedTransientEvents + [transientUserEvent].compactMap { $0 } + transientStreamEvents)
            .filter { shouldDisplayTransientEvent($0) }
    }

    private func retainCurrentTransientTranscript() {
        let current = ([transientUserEvent].compactMap { $0 } + transientStreamEvents)
            .filter { shouldDisplayTransientEvent($0) }
        guard !current.isEmpty else { return }
        for event in current where !retainedTransientEvents.contains(where: { $0.id == event.id }) {
            retainedTransientEvents.append(event)
        }
    }

    private func shouldDisplayTransientEvent(_ transientEvent: SessionEvent) -> Bool {
        switch transientEvent {
        case .message:
            return !latestPersistedMessage(matches: transientEvent, in: persistedEvents)
        case .toolCall(let call, _):
            return !persistedEvents.contains { event in
                guard case .toolCall(let persistedCall, _) = event else { return false }
                return persistedCall.id == call.id
            }
        case .toolResult(let result, _):
            return !persistedEvents.contains { event in
                guard case .toolResult(let persistedResult, _) = event else { return false }
                return persistedResult.id == result.id
                    || (!result.callId.isEmpty && persistedResult.callId == result.callId)
            }
        case .meta, .other:
            return true
        }
    }

    private func prependPersistedPage(_ page: SessionEventsPage, anchorEventID: String?) {
        let existingIDs = Set(persistedEvents.map(\.id))
        let filtered = page.events.filter { !existingIDs.contains($0.id) }
        guard !filtered.isEmpty else {
            hasEarlierHistory = page.hasMoreBefore
            return
        }
        pendingHistoryAnchorEventID = anchorEventID
        persistedEvents = mergePersistedEvents(persistedEvents, withFreshPage: filtered)
        hasEarlierHistory = page.hasMoreBefore
        reconcileTransientEvents(with: persistedEvents)
        rebuildEvents()
        historyRevision &+= 1
        statusMessage = "\(persistedEvents.count) events"
    }

    private func reconcileTransientEvents(with persisted: [SessionEvent]) {
        if let transientUserEvent,
           latestPersistedMessage(matches: transientUserEvent, in: persisted) {
            self.transientUserEvent = nil
        }
        if let transientAssistantEvent,
           latestPersistedMessage(matches: transientAssistantEvent, in: persisted) {
            self.transientAssistantEvent = nil
        }
        retainedTransientEvents.removeAll { event in
            transientEventIsPersisted(event, in: persisted)
        }
        transientStreamEvents.removeAll { event in
            transientEventIsPersisted(event, in: persisted)
        }
    }

    func markTurnOutputComplete() {
        guard isSending else { return }
        isAwaitingTurnCommit = true
        canAcceptSteering = false
        statusMessage = "Finalizing..."
        rebuildEvents()
    }

    private func completeSendReloadIfNeeded(for generation: Int?) {
        guard let generation,
              pendingSendCompletionGeneration == generation,
              sendGeneration == generation else {
            return
        }
        pendingSendCompletionGeneration = nil
        isSending = false
        isAwaitingTurnCommit = false
        canAcceptSteering = false
        rebuildEvents()
    }

    private func transientEventIsPersisted(_ event: SessionEvent, in persisted: [SessionEvent]) -> Bool {
        switch event {
        case .message:
            return latestPersistedMessage(matches: event, in: persisted)
        case .toolCall(let call, _):
            return persisted.contains { persistedEvent in
                guard case .toolCall(let persistedCall, _) = persistedEvent else { return false }
                return persistedCall.id == call.id
            }
        case .toolResult(let result, _):
            return persisted.contains { persistedEvent in
                guard case .toolResult(let persistedResult, _) = persistedEvent else { return false }
                return persistedResult.id == result.id
                    || (!result.callId.isEmpty && persistedResult.callId == result.callId)
            }
        case .meta, .other:
            return false
        }
    }

    private func upsertTransientStreamEvent(_ event: SessionEvent, into events: inout [SessionEvent]) {
        let matches: (SessionEvent) -> Bool = {
            switch (event, $0) {
            case (.message(let lhs, _), .message(let rhs, _)):
                if lhs.id == rhs.id { return true }
                return lhs.role == rhs.role
                    && !self.messageSignature(for: lhs).isEmpty
                    && self.messageSignature(for: lhs) == self.messageSignature(for: rhs)
            case (.toolCall(let lhs, _), .toolCall(let rhs, _)):
                return lhs.id == rhs.id
            case (.toolResult(let lhs, _), .toolResult(let rhs, _)):
                return lhs.id == rhs.id || (!lhs.callId.isEmpty && lhs.callId == rhs.callId)
            default:
                return false
            }
        }
        if let index = events.firstIndex(where: matches) {
            events[index] = eventWithLineIndex(event, events[index].lineIndex)
        } else {
            events.append(event)
        }
    }

    private func eventWithLineIndex(_ event: SessionEvent, _ lineIndex: Int) -> SessionEvent {
        switch event {
        case .meta(let meta, _):
            return .meta(meta, lineIndex: lineIndex)
        case .message(let message, _):
            return .message(message, lineIndex: lineIndex)
        case .toolCall(let call, _):
            return .toolCall(call, lineIndex: lineIndex)
        case .toolResult(let result, _):
            return .toolResult(result, lineIndex: lineIndex)
        case .other(let type, _):
            return .other(type: type, lineIndex: lineIndex)
        }
    }

    private func nextTransientLineIndex(for offset: Int) -> Int {
        Self.transientStreamLineIndexBase + offset
    }

    private func latestPersistedMessage(matches transientEvent: SessionEvent, in persisted: [SessionEvent]) -> Bool {
        guard case .message(let transientMessage, _) = transientEvent else { return false }
        let transientSignature = messageSignature(for: transientMessage)

        return persisted.contains { event in
            guard case .message(let persistedMessage, let lineIndex) = event,
                  lineIndex < Self.transientUserLineIndex,
                  persistedMessage.role == transientMessage.role else {
                return false
            }

            if persistedMessage.id == transientMessage.id {
                return true
            }

            let persistedSignature = messageSignature(for: persistedMessage)
            if !transientSignature.isEmpty, transientSignature == persistedSignature {
                return true
            }

            guard persistedMessage.content == transientMessage.content else {
                return false
            }
            if let transientTimestamp = transientMessage.timestamp,
               let persistedTimestamp = persistedMessage.timestamp {
                return abs(persistedTimestamp.timeIntervalSince(transientTimestamp)) < 30
            }
            return persistedMessage.parentId == transientMessage.parentId
        }
    }

    private func messageSignature(for message: Message) -> String {
        var textParts: [String] = []
        var thinkingParts: [String] = []
        var imageCount = 0

        for block in message.content {
            switch block {
            case .text(let text):
                let trimmed = normalizedMessageText(text)
                if !trimmed.isEmpty {
                    textParts.append(trimmed)
                }
            case .thinking(let text, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    thinkingParts.append(trimmed)
                }
            case .image:
                imageCount += 1
            }
        }

        var parts = textParts
        parts.append(contentsOf: thinkingParts.map { "[thinking]\($0)" })
        if imageCount > 0 {
            // Optimistic image prompts use local staged paths and order
            // attachments before text; persisted pi-appd rows may contain an
            // upload marker in text plus the image block after text/base64.
            // Match by visible text + image count rather than path/order.
            parts.append("[images:\(imageCount)]")
        }
        return parts.joined(separator: "\n")
    }

    private func normalizedMessageText(_ text: String) -> String {
        text
            // pi-appd persists image uploads as an empty <file ...></file>
            // text marker plus a real image content block. The optimistic
            // bubble only has the image block, so strip this transport marker
            // before matching transient rows to persisted JSONL rows.
            .replacingOccurrences(
                of: #"<file\b[^>]*>\s*</file>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let transientStreamLineIndexBase = Int.max - 1_000
    private static let transientUserLineIndex = Int.max - 1
    private static let transientAssistantLineIndex = Int.max
}

private extension String {
    var xmlEscapedForPrompt: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Multi-session store. Holds the list of open Pi sessions and the
/// currently selected tab. Replaces the old `TerminalWorkspaceStore`.
@MainActor
final class ChatSessionStore: ObservableObject {
    private let maximumCachedTabs = 40

    @Published private(set) var tabs: [ChatSession] = []
    @Published var selectedTabID: ChatSession.ID?

    /// Fired when a tab is closed (or its underlying process exits). The
    /// catalog layer uses this to schedule a refresh so newly created
    /// sessions show up in the sidebar.
    var onSessionExit: (() -> Void)?

    /// Fired on any mutation that affects the set of open tabs or the
    /// selected tab. The persistence layer hooks into this to keep the
    /// on-disk snapshot in sync. Not fired for transient state such as
    /// per-tab `loadError` or `isSending` because those are part of the
    /// runtime session, not the persisted shape.
    var onTabsChanged: (() -> Void)?

    var selectedTab: ChatSession? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    var hasTabs: Bool { !tabs.isEmpty }

    // MARK: - Tab management

    @discardableResult
    func openTab(
        key: String,
        title: String,
        sessionID: String? = nil,
        sessionPath: String? = nil,
        launchRequest: PiLaunchRequest? = nil,
        eventLoader: (@Sendable () async throws -> SessionEventsPage)? = nil,
        historyPageLoader: (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? = nil,
        autoLoad: Bool = true
    ) -> ChatSession {
        if let existing = tabs.first(where: { $0.key == key }) {
            existing.bindToSession(
                key: key,
                title: title,
                sessionID: sessionID,
                sessionPath: sessionPath,
                eventLoader: eventLoader,
                historyPageLoader: historyPageLoader
            )
            existing.updateLaunchRequest(launchRequest)
            select(existing)
            if autoLoad, !existing.isSending, (sessionPath != nil || eventLoader != nil) {
                existing.loadFromDisk(force: true)
            }
            return existing
        }

        // Chat-first UX: keep previously opened conversations alive in
        // memory so switching away and back preserves streaming state,
        // scroll position, and already loaded content.
        let session = ChatSession(
            key: key,
            title: title,
            sessionID: sessionID,
            sessionPath: sessionPath,
            launchRequest: launchRequest,
            eventLoader: eventLoader,
            historyPageLoader: historyPageLoader
        )
        tabs.append(session)
        select(session)
        if autoLoad, (sessionPath != nil || eventLoader != nil) {
            session.loadFromDisk()
        }
        trimCachedTabsIfNeeded()
        onTabsChanged?()
        return session
    }

    @discardableResult
    func openOrSelectTab(
        key: String,
        title: String,
        sessionID: String? = nil,
        sessionPath: String?,
        launchRequest: PiLaunchRequest? = nil,
        eventLoader: (@Sendable () async throws -> SessionEventsPage)? = nil,
        historyPageLoader: (@Sendable (_ before: Int, _ limit: Int) async throws -> SessionEventsPage)? = nil,
        autoLoad: Bool = true
    ) -> ChatSession {
        openTab(
            key: key,
            title: title,
            sessionID: sessionID,
            sessionPath: sessionPath,
            launchRequest: launchRequest,
            eventLoader: eventLoader,
            historyPageLoader: historyPageLoader,
            autoLoad: autoLoad
        )
    }

    func close(_ tab: ChatSession) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // Cancel any in-flight send before removing the tab so the
        // underlying process / HTTP stream is torn down promptly. The
        // task body is responsible for the rest of the cleanup; here
        // we just make sure we don't leak a detached process.
        tab.cancelSend()
        let wasSelected = selectedTabID == tab.id
        tabs.remove(at: index)
        if wasSelected {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                selectedTabID = tabs.last?.id
            }
        }
        onSessionExit?()
        onTabsChanged?()
    }

    /// Close every open tab. Used when the host changes so the user does
    /// not see stale conversations from the previous host. After this call
    /// `selectedTabID` is `nil` and the workspace is empty.
    ///
    /// - Parameter notify: when `true` (the default) `onSessionExit` fires
    ///   so observers can schedule a catalog refresh. Pass `false` when
    ///   the caller is already triggering a refresh itself (e.g.
    ///   `PiAppState.clearCatalog` immediately calls `refreshCatalog`
    ///   afterwards).
    func closeAll(notify: Bool = true) {
        guard !tabs.isEmpty else { return }
        // Cancel active sends across every tab before wiping the list.
        // The task bodies finish on their own and quietly observe the
        // cancellation.
        for tab in tabs {
            tab.cancelSend()
        }
        tabs.removeAll()
        selectedTabID = nil
        if notify { onSessionExit?() }
        onTabsChanged?()
    }

    func closeDuplicateTabs(keeping keptTab: ChatSession, matchingAliases aliases: [String]) {
        let aliasSet = Set(aliases.compactMap { $0.nilIfBlank })
        guard !aliasSet.isEmpty else { return }
        let removedSelectedTab = tabs.contains { tab in
            tab.id != keptTab.id
                && selectedTabID == tab.id
                && !aliasSet.isDisjoint(with: Set(Self.aliases(for: tab)))
        }
        let originalCount = tabs.count
        tabs.removeAll { tab in
            guard tab.id != keptTab.id,
                  !aliasSet.isDisjoint(with: Set(Self.aliases(for: tab))) else {
                return false
            }
            tab.cancelSend()
            return true
        }
        guard tabs.count != originalCount else { return }
        if removedSelectedTab || selectedTabID == nil {
            selectedTabID = keptTab.id
        }
        onSessionExit?()
        onTabsChanged?()
    }

    func select(_ tab: ChatSession) {
        let previousSelection = selectedTabID
        var didReorder = false
        selectedTabID = tab.id
        if let index = tabs.firstIndex(where: { $0.id == tab.id }), index != tabs.count - 1 {
            let cached = tabs.remove(at: index)
            tabs.append(cached)
            didReorder = true
        }
        if previousSelection != selectedTabID || didReorder {
            onTabsChanged?()
        }
    }

    private static func aliases(for tab: ChatSession) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for alias in [tab.sessionID, tab.sessionPath, tab.key] {
            guard let value = alias?.nilIfBlank, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private func trimCachedTabsIfNeeded() {
        while tabs.count > maximumCachedTabs {
            guard let index = tabs.firstIndex(where: { $0.id != selectedTabID && !$0.hasActiveSend }) else {
                break
            }
            tabs.remove(at: index)
        }
    }
}

private enum SessionLoadOutcome: Sendable {
    case skipped
    case notBackedByFile
    case loaded(SessionEventsPage, modificationDate: Date?)
    case failed(String)
}

private enum SessionLoadWorker {
    static func load(
        sessionPath: String?,
        eventLoader: (@Sendable () async throws -> SessionEventsPage)?,
        force: Bool,
        previousLoadedOnce: Bool,
        previousModificationDate: Date?
    ) async -> SessionLoadOutcome {
        do {
            let page: SessionEventsPage
            let modificationDate: Date?

            if let eventLoader {
                page = try await eventLoader()
                modificationDate = nil
            } else if let sessionPath {
                let fileURL = URL(fileURLWithPath: sessionPath)
                let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                modificationDate = resourceValues?.contentModificationDate
                if !force && previousLoadedOnce && modificationDate == previousModificationDate {
                    return .skipped
                }
                page = SessionEventsPage.fromEvents(try SessionEventParser.parse(fileURL: fileURL))
            } else {
                return .notBackedByFile
            }

            return .loaded(page, modificationDate: modificationDate)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
