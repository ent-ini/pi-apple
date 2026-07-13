import Foundation
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

private actor SessionEventsPageBox {
    private var page: SessionEventsPage

    init(_ page: SessionEventsPage) {
        self.page = page
    }

    func get() -> SessionEventsPage {
        page
    }

    func set(_ page: SessionEventsPage) {
        self.page = page
    }
}

private actor IntBox {
    private var value: Int?

    func get() -> Int? {
        value
    }

    func set(_ value: Int?) {
        self.value = value
    }
}

// MARK: - ChatSession cancellation

@MainActor
@Test func chatSessionStartsWithoutActiveSend() {
    let session = ChatSession(key: "test", title: "Test")

    #expect(session.sendTask == nil)
    #expect(session.hasActiveSend == false)
}

@MainActor
@Test func chatSessionCancelSendIsSafeWhenNoTask() {
    let session = ChatSession(key: "test", title: "Test")

    // Should be a no-op rather than crashing.
    session.cancelSend()

    #expect(session.sendTask == nil)
    #expect(session.hasActiveSend == false)
}

@MainActor
@Test func chatSessionCancelSendCancelsActiveTask() async throws {
    let session = ChatSession(key: "test", title: "Test")
    let task = Task<Void, Never> {
        // Long-running dummy work that the test will cancel.
        try? await Task.sleep(for: .seconds(30))
    }
    session.sendTask = task

    #expect(session.hasActiveSend)
    #expect(task.isCancelled == false)

    session.cancelSend()

    // The reference is cleared synchronously so the store / view can
    // observe the new state immediately.
    #expect(session.sendTask == nil)
    #expect(session.hasActiveSend == false)
    // The underlying task received the cancellation signal.
    #expect(task.isCancelled)
}

@MainActor
@Test func chatSessionCancelSendTwiceIsIdempotent() async throws {
    let session = ChatSession(key: "test", title: "Test")
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    session.sendTask = task

    session.cancelSend()
    session.cancelSend()

    #expect(session.sendTask == nil)
    #expect(task.isCancelled)
}

@MainActor
@Test func chatSessionFinishSendingCancelledClearsTransientState() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")

    #expect(session.isSending)

    session.finishSendingCancelled()

    #expect(session.isSending == false)
    #expect(session.statusMessage.isEmpty)
}

@MainActor
@Test func chatSessionAbortPreservesTransientTranscriptAndAddsAbortEvent() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")
    session.applyStreamingEvents(
        [
            .message(
                Message(id: "assistant-1", role: .assistant, content: [.text("partial")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    session.recordAbortAcknowledged()

    #expect(session.isSending)
    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .user }
        return false
    })
    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .assistant && message.content == [.text("partial")] }
        return false
    })
    #expect(session.events.contains { event in
        if case .other(let type, _) = event { return type == "abort" }
        return false
    })
}

@MainActor
@Test func chatSessionReconcilesImagePromptWhenPersistedAttachmentPathDiffers() {
    let session = ChatSession(key: "test", title: "Test")
    let attachment = ChatAttachment(
        kind: .image,
        fileURL: URL(fileURLWithPath: "/tmp/local-staged-photo.png"),
        displayName: "photo.png",
        mimeType: "image/png",
        size: 123
    )

    session.beginSending(prompt: "[source:pi-app type=text]\nчто на фото?", attachments: [attachment])
    session.appendPersistedEvents([
        .message(
            Message(
                id: "persisted-user",
                role: .user,
                content: [
                    .text("<file name=\"/home/agent/.pi/agent/uploads/photo.png\"></file>\n\n[source:pi-app type=text]\nчто на фото?"),
                    .image(path: "data:image/png;base64,abc", mime: "image/png")
                ],
                model: nil,
                timestamp: Date(),
                parentId: nil
            ),
            lineIndex: 0
        ),
        .message(
            Message(id: "persisted-assistant", role: .assistant, content: [.text("Ответ")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 1
        )
    ])

    let userMessages = session.events.compactMap { event -> Message? in
        guard case .message(let message, _) = event,
              message.role == .user else { return nil }
        return message
    }
    #expect(userMessages.map(\.id) == ["persisted-user"])
}

@MainActor
@Test func chatSessionReconcilesFilePromptWhenPersistedFileIsExpanded() {
    let session = ChatSession(key: "test", title: "Test")
    let attachment = ChatAttachment(
        kind: .file,
        fileURL: URL(fileURLWithPath: "/Users/artemiy/Library/Application Support/ApplePi/attachments/list.md"),
        displayName: "list.md",
        mimeType: "text/markdown",
        size: 456
    )

    let prompt = "[source:pi-app type=text]\nперенеси отмеченные"
    session.beginSending(prompt: prompt, attachments: [attachment])
    session.appendPersistedEvents([
        .message(
            Message(
                id: "persisted-user",
                role: .user,
                content: [
                    .text("<file name=\"/home/agent/.pi/agent/uploads/list-123.md\">\n# List\n\n| id | Import |\n|---:|---|\n| 1 | х |\n</file>\n\n\(prompt)")
                ],
                model: nil,
                timestamp: Date(),
                parentId: nil
            ),
            lineIndex: 0
        )
    ])

    let userMessages = session.events.compactMap { event -> Message? in
        guard case .message(let message, _) = event,
              message.role == .user else { return nil }
        return message
    }
    #expect(userMessages.map(\.id) == ["persisted-user"])
}

@MainActor
@Test func chatSessionDoesNotHideRepeatedPromptFromOlderPersistedTurn() {
    let session = ChatSession(key: "test", title: "Test")
    session.appendPersistedEvents([
        .message(
            Message(
                id: "old-user",
                role: .user,
                content: [.text("same prompt")],
                model: nil,
                timestamp: Date(timeIntervalSinceNow: -120),
                parentId: nil
            ),
            lineIndex: 0
        ),
        .message(
            Message(id: "old-assistant", role: .assistant, content: [.text("old answer")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 1
        )
    ])

    session.beginSending(prompt: "same prompt")

    let userMessages = session.events.compactMap { event -> Message? in
        guard case .message(let message, _) = event, message.role == .user else { return nil }
        return message
    }
    #expect(userMessages.count == 2)
    #expect(userMessages.map(\.id).contains("old-user"))
}

@MainActor
@Test func chatSessionDoesNotHideSameTextAssistantStreamAgainstOlderPersistedTurn() {
    let session = ChatSession(key: "test", title: "Test")
    session.appendPersistedEvents([
        .message(
            Message(id: "old-assistant", role: .assistant, content: [.text("same answer")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 0
        )
    ])

    session.beginSending(prompt: "again")
    session.applyStreamingEvents([
        .message(
            Message(id: "new-assistant", role: .assistant, content: [.text("same answer")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 1
        )
    ], isFinal: false)

    let assistantIDs = session.events.compactMap { event -> String? in
        guard case .message(let message, _) = event,
              message.role == .assistant else { return nil }
        return message.id
    }
    #expect(assistantIDs == ["old-assistant", "new-assistant"])
}

@MainActor
@Test func chatSessionReconcilesSameTextAssistantStreamWithNewPersistedTurnOnlyOnce() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "again")
    session.applyStreamingEvents([
        .message(
            Message(id: "stream-a", role: .assistant, content: [.text("same answer")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 0
        ),
        .message(
            Message(id: "stream-b", role: .assistant, content: [.text("same answer")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 1
        )
    ], isFinal: false)

    session.appendPersistedEvents([
        .message(
            Message(id: "persisted-a", role: .assistant, content: [.text("same answer")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 0
        )
    ])

    let assistantIDs = session.events.compactMap { event -> String? in
        guard case .message(let message, _) = event,
              message.role == .assistant else { return nil }
        return message.id
    }
    #expect(assistantIDs == ["persisted-a", "stream-b"])
}

@MainActor
@Test func chatSessionReconcilesAssistantFileReferenceAcrossLiveAndPersistedForms() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "send the file")
    session.applyStreamingEvents([
        .message(
            Message(
                id: "live-assistant",
                role: .assistant,
                content: [.text("Here is the file: @/home/agent/ai-agent/workspace/output/result.pdf")],
                model: nil,
                timestamp: nil,
                parentId: nil
            ),
            lineIndex: 0
        )
    ], isFinal: false)

    session.appendPersistedEvents([
        .message(
            Message(
                id: "persisted-assistant",
                role: .assistant,
                content: [.text("Here is the file: <file name=\"pi-attachment://att_0123456789abcdef0123456789abcdef/result.pdf\" attachment-id=\"att_0123456789abcdef0123456789abcdef\" attachment-name=\"result.pdf\" attachment-mime=\"application/pdf\">[File attached: result.pdf]</file>")],
                model: nil,
                timestamp: nil,
                parentId: nil
            ),
            lineIndex: 1
        )
    ])

    let assistantMessages = session.events.compactMap { event -> Message? in
        guard case .message(let message, _) = event,
              message.role == .assistant else { return nil }
        return message
    }
    #expect(assistantMessages.map(\.id) == ["persisted-assistant"])
}

@MainActor
@Test func chatSessionDoesNotExposeSyntheticAssistantPlaceholderBeforeStreamEventsArrive() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")

    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .user }
        return false
    })
    #expect(!session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .assistant }
        return false
    })

    session.applyStreamingEvents(
        [
            .message(
                Message(
                    id: "assistant-1",
                    role: .assistant,
                    content: [.text("Hi there")],
                    model: nil,
                    timestamp: nil,
                    parentId: nil
                ),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.role == .assistant && message.content == [.text("Hi there")] }
        return false
    })
}

@MainActor
@Test func chatSessionKeepsAbortAndQueuedInputInObservedOrder() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "first")
    session.applyStreamingEvents(
        [
            .message(
                Message(id: "assistant-1", role: .assistant, content: [.text("partial")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    session.abortSend()
    session.appendSteeringPrompt("after abort")

    let visibleMessages = session.events.compactMap { event -> String? in
        guard case .message(let message, _) = event else { return nil }
        let text = message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: " ")
        return "\(message.role.rawValue):\(text)"
    }

    #expect(visibleMessages == [
        "user:first",
        "assistant:partial",
        "user:/abort",
        "user:after abort"
    ])
}

@MainActor
@Test func chatSessionAppendsNewFollowUpAfterRetainedTransientTranscript() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "first")
    session.applyStreamingEvents(
        [
            .message(
                Message(id: "assistant-1", role: .assistant, content: [.text("partial")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    session.finishSendingWithError("transport closed")
    session.beginSending(prompt: "second")

    let visibleMessages = session.events.compactMap { event -> String? in
        guard case .message(let message, _) = event else { return nil }
        let text = message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: " ")
        return "\(message.role.rawValue):\(text)"
    }

    #expect(visibleMessages == [
        "user:first",
        "assistant:partial",
        "user:second"
    ])
}

@MainActor
@Test func chatSessionKeepsStreamEventsInWireOrder() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "hello")

    session.applyStreamingEvents(
        [
            .message(
                Message(id: "assistant-1", role: .assistant, content: [.text("I'll check")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            ),
            .toolCall(.function(id: "call-1", name: "read", arguments: "{}"), lineIndex: 0),
            .toolResult(.result(id: "result-1", callId: "call-1", toolName: "read", output: "ok", isError: false), lineIndex: 0),
            .message(
                Message(id: "assistant-2", role: .assistant, content: [.text("Done")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            )
        ],
        isFinal: false
    )

    let roles = session.events.map { event -> String in
        switch event {
        case .message(let message, _): return "message:\(message.role.rawValue):\(message.id)"
        case .toolCall(let call, _): return "toolCall:\(call.id)"
        case .toolResult(let result, _): return "toolResult:\(result.callId)"
        case .meta, .other: return "other"
        }
    }

    #expect(roles.first?.hasPrefix("message:user:") == true)
    #expect(Array(roles.dropFirst()) == [
        "message:assistant:assistant-1",
        "toolCall:call-1",
        "toolResult:call-1",
        "message:assistant:assistant-2"
    ])
}

@MainActor
@Test func chatSessionAppendsLatePersistedEventsWithoutMovingVisibleRows() {
    let session = ChatSession(key: "test", title: "Test")
    session.appendPersistedEvents([
        .message(
            Message(id: "m1", role: .assistant, content: [.text("one")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 1
        ),
        .message(
            Message(id: "m3", role: .assistant, content: [.text("three")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 3
        )
    ])

    session.appendPersistedEvents([
        .message(
            Message(id: "m2", role: .user, content: [.text("two")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 2
        )
    ])

    let orderedIDs = session.events.compactMap { event -> String? in
        guard case .message(let message, _) = event else { return nil }
        return message.id
    }
    #expect(orderedIDs == ["m1", "m3", "m2"])
    // Source-line bookkeeping still observes the real latest persisted row for
    // pagination/catch-up, even though display order remains append-stable.
    #expect(session.lastPersistedLineIndex == 3)
}

@MainActor
@Test func chatSessionPersistedAbortReplacementPreservesFirstSeenOrder() {
    let session = ChatSession(key: "test", title: "Test")
    session.beginSending(prompt: "first")
    session.applyStreamingEvents([
        .message(
            Message(id: "partial", role: .assistant, content: [.text("working")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 0
        )
    ], isFinal: false)
    session.abortSend()
    session.appendSteeringPrompt("after abort")

    session.appendPersistedEvents([
        .message(
            Message(id: "persisted-first", role: .user, content: [.text("first")], model: nil, timestamp: Date(), parentId: nil),
            lineIndex: 10
        ),
        .message(
            Message(id: "persisted-partial", role: .assistant, content: [.text("working")], model: nil, timestamp: nil, parentId: nil),
            lineIndex: 11
        ),
        // Simulate a catch-up/reload where the follow-up has an earlier JSONL
        // line than the abort acknowledgement. The UI must keep the order the
        // user saw: /abort first, then the next prompt.
        .message(
            Message(id: "persisted-after", role: .user, content: [.text("after abort")], model: nil, timestamp: Date(), parentId: nil),
            lineIndex: 12
        ),
        .message(
            Message(id: "persisted-abort", role: .user, content: [.text("/abort")], model: nil, timestamp: Date(), parentId: nil),
            lineIndex: 13
        )
    ])

    let userTexts = session.events.compactMap { event -> String? in
        guard case .message(let message, _) = event, message.role == .user else { return nil }
        guard case .text(let text) = message.content.first else { return nil }
        return text
    }
    #expect(userTexts == ["first", "/abort", "after abort"])
}

@MainActor
@Test func chatSessionInitialRemotePageTracksEarlierHistoryAvailability() async throws {
    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: {
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m2", role: .assistant, content: [.text("new")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 2
                    )
                ],
                firstLine: 2,
                lastLine: 2,
                hasMoreBefore: true,
                hasMoreAfter: false
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 2 }

    #expect(session.hasEarlierHistory)
    #expect(session.firstPersistedLineIndex == 2)
}

@MainActor
@Test func chatSessionDeltaAppendDoesNotExposeAlreadyLoadedEarlierHistory() async throws {
    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: {
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m0", role: .user, content: [.text("first")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 0
                    )
                ],
                firstLine: 0,
                lastLine: 0,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 0 }
    #expect(session.hasEarlierHistory == false)

    session.appendPersistedPage(SessionEventsPage(
        events: [
            .message(
                Message(id: "m1", role: .assistant, content: [.text("reply")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 1
            )
        ],
        firstLine: 1,
        lastLine: 1,
        hasMoreBefore: true,
        hasMoreAfter: false
    ))

    #expect(session.firstPersistedLineIndex == 0)
    #expect(session.lastPersistedLineIndex == 1)
    #expect(session.hasEarlierHistory == false)
}

@MainActor
@Test func chatSessionEmptyDeltaDoesNotExposeAlreadyLoadedEarlierHistory() async throws {
    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: {
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m0", role: .user, content: [.text("first")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 0
                    )
                ],
                firstLine: 0,
                lastLine: 0,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 0 }

    session.appendPersistedPage(SessionEventsPage(
        events: [],
        firstLine: 0,
        lastLine: 0,
        hasMoreBefore: true,
        hasMoreAfter: false
    ))

    #expect(session.firstPersistedLineIndex == 0)
    #expect(session.hasEarlierHistory == false)
}

@MainActor
@Test func chatSessionPagedReloadKeepsPreviouslyLoadedRowsVisible() async throws {
    let pageBox = SessionEventsPageBox(SessionEventsPage(
        events: [
            .message(
                Message(id: "m10", role: .assistant, content: [.text("ten")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 10
            )
        ],
        firstLine: 10,
        lastLine: 10,
        hasMoreBefore: true,
        hasMoreAfter: false
    ))

    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: { await pageBox.get() },
        historyPageLoader: { _, _ in
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m5", role: .user, content: [.text("older user prompt")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 5
                    )
                ],
                firstLine: 5,
                lastLine: 5,
                hasMoreBefore: true,
                hasMoreAfter: true
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 10 }
    session.loadEarlierHistory(limit: 60)
    try await waitUntil { session.firstPersistedLineIndex == 5 }

    await pageBox.set(SessionEventsPage(
        events: [
            .message(
                Message(id: "m11", role: .assistant, content: [.text("eleven")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 11
            )
        ],
        firstLine: 11,
        lastLine: 11,
        hasMoreBefore: true,
        hasMoreAfter: false
    ))
    session.loadFromDisk(force: true)
    try await waitUntil { session.lastPersistedLineIndex == 11 }

    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.id == "m5" }
        return false
    })
    #expect(session.events.contains { event in
        if case .message(let message, _) = event { return message.id == "m11" }
        return false
    })
}

@MainActor
@Test func chatSessionForcedReloadMiddleGapCanBeRecoveredWithHistoryLoader() async throws {
    let pageBox = SessionEventsPageBox(SessionEventsPage(
        events: [
            .message(
                Message(id: "m0", role: .user, content: [.text("zero")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            ),
            .message(
                Message(id: "m1", role: .assistant, content: [.text("one")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 1
            )
        ],
        firstLine: 0,
        lastLine: 1,
        hasMoreBefore: false,
        hasMoreAfter: false
    ))
    let requestedBefore = IntBox()

    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: { await pageBox.get() },
        historyPageLoader: { before, _ in
            await requestedBefore.set(before)
            return SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m2", role: .user, content: [.text("two")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 2
                    ),
                    .message(
                        Message(id: "m3", role: .assistant, content: [.text("three")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 3
                    ),
                    .message(
                        Message(id: "m4", role: .user, content: [.text("four")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 4
                    )
                ],
                firstLine: 2,
                lastLine: 4,
                hasMoreBefore: false,
                hasMoreAfter: true
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.lastPersistedLineIndex == 1 }
    await pageBox.set(SessionEventsPage(
        events: [
            .message(
                Message(id: "m5", role: .assistant, content: [.text("five")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 5
            )
        ],
        firstLine: 5,
        lastLine: 5,
        hasMoreBefore: true,
        hasMoreAfter: false
    ))

    session.loadFromDisk(force: true)
    try await waitUntil { session.lastPersistedLineIndex == 5 }
    #expect(session.hasEarlierHistory)

    session.loadEarlierHistory(limit: 120)
    try await waitUntil { session.events.contains { event in
        if case .message(let message, _) = event { return message.id == "m4" }
        return false
    } }

    #expect(await requestedBefore.get() == 5)
    #expect(session.events.compactMap { event -> Int? in
        if case .message(_, let lineIndex) = event { return lineIndex }
        return nil
    } == [0, 1, 2, 3, 4, 5])
    #expect(session.hasEarlierHistory == false)
}

@MainActor
@Test func chatSessionLoadEarlierHistoryPrependsEventsAndExposesAnchor() async throws {
    let initialPage = SessionEventsPage(
        events: [
            .message(
                Message(id: "m2", role: .assistant, content: [.text("two")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 2
            ),
            .message(
                Message(id: "m3", role: .assistant, content: [.text("three")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 3
            )
        ],
        firstLine: 2,
        lastLine: 3,
        hasMoreBefore: true,
        hasMoreAfter: false
    )
    let olderPage = SessionEventsPage(
        events: [
            .message(
                Message(id: "m0", role: .assistant, content: [.text("zero")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 0
            ),
            .message(
                Message(id: "m1", role: .assistant, content: [.text("one")], model: nil, timestamp: nil, parentId: nil),
                lineIndex: 1
            )
        ],
        firstLine: 0,
        lastLine: 1,
        hasMoreBefore: false,
        hasMoreAfter: true
    )

    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: { initialPage },
        historyPageLoader: { before, _ in
            precondition(before == 2)
            return olderPage
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 2 }
    session.loadEarlierHistory(limit: 120, preserveVisiblePosition: true)
    try await waitUntil { session.firstPersistedLineIndex == 0 }

    #expect(session.firstPersistedLineIndex == 0)
    #expect(session.hasEarlierHistory == false)
    #expect(session.pendingHistoryAnchorID == "message:m2")
    #expect(session.consumePendingHistoryAnchorID() == "message:m2")
}

@MainActor
@Test func chatSessionNonUserInitiatedHistoryLoadDoesNotExposeScrollAnchor() async throws {
    let session = ChatSession(
        key: "test",
        title: "Test",
        eventLoader: {
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m2", role: .assistant, content: [.text("two")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 2
                    )
                ],
                firstLine: 2,
                lastLine: 2,
                hasMoreBefore: true,
                hasMoreAfter: false
            )
        },
        historyPageLoader: { _, _ in
            SessionEventsPage(
                events: [
                    .message(
                        Message(id: "m1", role: .assistant, content: [.text("one")], model: nil, timestamp: nil, parentId: nil),
                        lineIndex: 1
                    )
                ],
                firstLine: 1,
                lastLine: 1,
                hasMoreBefore: true,
                hasMoreAfter: true
            )
        }
    )

    session.loadFromDisk(force: true)
    try await waitUntil { session.firstPersistedLineIndex == 2 }
    session.loadEarlierHistory(limit: 120, preserveVisiblePosition: false)
    try await waitUntil { session.firstPersistedLineIndex == 1 }

    #expect(session.pendingHistoryAnchorID == nil)
    #expect(session.consumePendingHistoryAnchorID() == nil)
}

// MARK: - ChatSessionStore close/closeAll cancellation

@MainActor
@Test func chatSessionStoreCloseCancelsActiveSend() async throws {
    let store = ChatSessionStore()
    let session = store.openTab(key: "test", title: "Test")
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    session.sendTask = task

    store.close(session)

    #expect(store.tabs.isEmpty)
    #expect(session.sendTask == nil)
    #expect(task.isCancelled)
}

@MainActor
@Test func chatSessionStoreCloseAllCancelsActiveSends() async throws {
    let store = ChatSessionStore()
    let sessionA = store.openTab(key: "a", title: "A")
    let sessionB = store.openTab(key: "b", title: "B")
    let taskA = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    let taskB = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    sessionA.sendTask = taskA
    sessionB.sendTask = taskB

    store.closeAll()

    #expect(store.tabs.isEmpty)
    #expect(store.selectedTabID == nil)
    #expect(taskA.isCancelled)
    #expect(taskB.isCancelled)
}

@MainActor
@Test func chatSessionStoreCloseAllOnEmptyStoreIsNoop() {
    let store = ChatSessionStore()
    var onExitCalls = 0
    store.onSessionExit = { onExitCalls += 1 }

    store.closeAll()

    #expect(store.tabs.isEmpty)
    #expect(onExitCalls == 0)
}

@MainActor
@Test func chatSessionStoreCloseIsNoopForUnknownTab() async throws {
    let store = ChatSessionStore()
    let session = ChatSession(key: "test", title: "Test")
    // Note: session is not appended to `store.tabs`.
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
    session.sendTask = task

    store.close(session)

    // The unknown tab is not removed and its task is untouched.
    #expect(store.tabs.isEmpty)
    #expect(task.isCancelled == false)
}

// MARK: - PiAppState send lifecycle

@MainActor
@Test func piAppStateSendMessageStoresTaskOnSession() async throws {
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    // Skip the update check so the test does not hit the network.
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    let session = state.chatWorkspace.openTab(
        key: "test",
        title: "Test",
        sessionPath: nil,
        launchRequest: nil
    )

    let didStart = state.sendMessage("hello", in: session)

    #expect(didStart)
    #expect(session.isSending)
    #expect(session.hasActiveSend)
    #expect(session.sendTask != nil)

    // Cancel via the public API and wait for the task body to finish.
    let task = session.sendTask
    session.cancelSend()
    _ = await task?.value

    #expect(session.sendTask == nil)
    #expect(session.isSending == false)
    #expect(session.hasActiveSend == false)
}

@MainActor
@Test func piAppStateSendMessageRefusesToMutateClosedSession() async throws {
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    var session: ChatSession? = state.chatWorkspace.openTab(
        key: "test",
        title: "Test",
        sessionPath: nil,
        launchRequest: nil
    )

    let didStart = state.sendMessage("hello", in: session!)
    #expect(didStart)

    // Close the tab *while* the send is running. `close(_:)` cancels
    // the task and removes the session from the store. The task body
    // must observe the weak reference and avoid touching the session
    // (it is fine for it to keep running in the background until the
    // process is reaped).
    let task = session?.sendTask
    state.chatWorkspace.close(session!)

    // Drop the only strong reference to the session. The task body
    // holds it weakly, so it must observe `nil` and exit cleanly
    // without trying to mutate deallocated state.
    session = nil

    // Wait for the task body to complete. It should not crash even
    // though the session is gone.
    _ = await task?.value
}

@MainActor
@Test func piAppStateCloseAllCancelsActiveSends() async throws {
    let fixture = try LongRunningScriptFixture()
    defer { fixture.cleanup() }

    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(piExecutable: fixture.scriptPath, agentDirectory: fixture.directory)
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")

    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )
    let session = state.chatWorkspace.openTab(
        key: "test",
        title: "Test",
        sessionPath: nil,
        launchRequest: nil
    )

    let didStart = state.sendMessage("hello", in: session)
    #expect(didStart)
    let task = session.sendTask
    #expect(task != nil)

    state.chatWorkspace.closeAll()

    // The send task is cancelled and the session is removed.
    #expect(state.chatWorkspace.tabs.isEmpty)
    #expect(task?.isCancelled == true)
}

// MARK: - Helpers

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !predicate() {
        if start.duration(to: ContinuousClock.now) > timeout {
            throw TestTimeoutError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct TestTimeoutError: Error {}

private enum TestSendOutcome: Equatable, Sendable {
    case success
    case cancelled
    case failure(String)
}

/// Creates a self-executing shell script that sleeps for a long time
/// and ignores its arguments. Used as a stand-in for the real `pi`
/// process so we can exercise the cancellation paths without
/// requiring a working `pi` installation in the test environment.
private final class LongRunningScriptFixture {
    let directory: String
    let scriptPath: String

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplePiSendLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        directory = root.path
        let script = root.appendingPathComponent("sleep-stand-in.sh")
        // 30s is far longer than any reasonable test timeout, so a
        // healthy cancellation path must terminate the process well
        // before it elapses.
        try """
        #!/bin/sh
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        scriptPath = script.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    deinit {
        cleanup()
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ApplePiSendLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
