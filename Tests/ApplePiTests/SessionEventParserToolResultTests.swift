import Foundation
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

/// Covers the `message.role == "toolResult"` JSONL shape, inline
/// `toolCall` content blocks inside assistant messages, and the legacy
/// top-level `type: "tool_use"` / `type: "tool_call"` / `type: "tool_result"`
/// lines. The existing `ApplePiTests.swift` only checked the legacy
/// shapes with string payloads, so the realistic Anthropic-style
/// `toolResult` role and structured `toolCall` blocks deserve their own
/// home to keep regressions easy to spot.
@Suite("SessionEventParser — tool calls and results")
struct SessionEventParserToolResultTests {

    @Test
    func toolResultRoleMessageIsDecodedAsToolResultEvent() {
        // The real Pi wire format stores tool outcomes as a normal
        // `type: "message"` line whose `message.role` is `toolResult`.
        // Previously the parser dropped these (the role failed to match
        // `user` / `assistant` / `system`). They must now surface as a
        // `SessionEvent.toolResult` instead of vanishing.
        let raw = #"""
        {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-06-01T10:00:00.000Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read_file","content":[{"type":"text","text":"file contents"}],"isError":false,"timestamp":1717230000000}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        guard let event = events.first else {
            Issue.record("Expected a single event from the toolResult line")
            return
        }
        guard case .toolResult(let result, let lineIndex) = event else {
            Issue.record("Expected .toolResult, got \(event)")
            return
        }
        #expect(lineIndex == 0)
        #expect(result.id == "a1")
        #expect(result.callId == "call-1")
        #expect(result.toolName == "read_file")
        #expect(result.isError == false)
        #expect(result.output.contains("file contents"))
    }

    @Test
    func toolResultRoleMessagePropagatesIsErrorAndMissingToolName() {
        // Pi marks failed tools with `isError: true` and older sessions
        // sometimes omit `toolName` on the result. The parser must keep
        // both signals so the chat view can render them.
        let raw = #"""
        {"type":"message","id":"e1","message":{"role":"toolResult","toolCallId":"call-2","content":"boom","isError":true}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        guard case .toolResult(let result, _) = events.first else {
            Issue.record("Expected .toolResult")
            return
        }
        #expect(result.callId == "call-2")
        #expect(result.toolName == nil)
        #expect(result.isError == true)
        #expect(result.output == "boom")
    }

    @Test
    func toolResultRoleMessageRetainsRawDetailsForSubagentTranscriptParsing() {
        let raw = #"""
        {"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"call-subagent","toolName":"subagent","content":"done","isError":false,"details":{"results":[{"messages":[{"role":"user","content":"nested task","timestamp":1717230000000},{"role":"assistant","content":[{"type":"thinking","thinking":"thought"},{"type":"toolCall","id":"nested-call","name":"read","arguments":{"path":"a.txt"}},{"type":"text","text":"final text"}],"timestamp":1717230001000},{"role":"toolResult","toolCallId":"nested-call","toolName":"read","content":"contents","isError":false,"timestamp":1717230002000}]}]}}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        guard case .toolResult(let result, _) = events.first else {
            Issue.record("Expected .toolResult")
            return
        }
        #expect(result.output.contains("done"))
        #expect(result.detailsJSON?.contains("nested-call") == true)
        #expect(result.detailsJSON?.contains("final text") == true)
    }

    @Test
    func subagentExtractionBuildsNewestFirstNestedReadableTranscript() {
        let lines = [
            #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-old","name":"subagent","arguments":{"task":"old task","temporaryAgent":{"name":"Old","model":"openai/old"}}}]}}"#,
            #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"call-old","toolName":"subagent","content":"old done","isError":false,"details":{"results":[{"messages":[{"role":"user","content":"old task"},{"role":"assistant","content":"old answer"}]}]}}}"#,
            #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-new","name":"subagent","arguments":{"task":"new task","temporaryAgent":{"name":"New","model":"openai/new"}}}]}}"#,
            #"{"type":"message","id":"r2","message":{"role":"toolResult","toolCallId":"call-new","toolName":"subagent","content":"new done","isError":false,"details":{"results":[{"messages":[{"role":"user","content":"new task","timestamp":1717230000000},{"role":"assistant","content":[{"type":"thinking","thinking":"thought"},{"type":"toolCall","id":"nested-call","name":"read","arguments":{"path":"a.txt"}},{"type":"text","text":"final text"}],"timestamp":1717230001000},{"role":"toolResult","toolCallId":"nested-call","toolName":"read","content":"contents","isError":false,"timestamp":1717230002000}]}]}}}"#
        ]

        let subagents = SubagentSession.extract(from: SessionEventParser.parse(lines: lines))

        #expect(subagents.map(\.name) == ["New", "Old"])
        let newestEvents = subagents.first?.events ?? []
        #expect(newestEvents.contains {
            if case .toolCall(let call, _) = $0 { return call.id == "nested-call" }
            return false
        })
        #expect(newestEvents.contains {
            if case .toolResult(let result, _) = $0 { return result.output == "contents" }
            return false
        })
        #expect(newestEvents.contains {
            if case .message(let message, _) = $0 {
                return message.content.contains { block in
                    if case .thinking(let text, _) = block { return text == "thought" }
                    return false
                }
            }
            return false
        })
    }

    @Test
    func toolResultRoleMessageRendersStructuredTextContentAsPlainOutput() {
        // Some tools return `content` as an array of typed text blocks.
        // The UI should show the tool's actual text output, not raw JSON.
        let raw = #"""
        {"type":"message","id":"a2","message":{"role":"toolResult","toolCallId":"call-3","toolName":"ls","content":[{"type":"text","text":"a.txt"},{"type":"text","text":"b.txt"}],"isError":false}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        guard case .toolResult(let result, _) = events.first else {
            Issue.record("Expected .toolResult")
            return
        }
        #expect(result.output == "a.txt\nb.txt")
    }

    @Test
    func toolResultRoleMessageWithoutContentFallsBackToEmptyOutput() {
        // Defensive: a tool that finishes without content (rare, but
        // possible for image-only payloads) should not crash the parser.
        let raw = #"""
        {"type":"message","id":"a3","message":{"role":"toolResult","toolCallId":"call-4","isError":false}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        guard case .toolResult(let result, _) = events.first else {
            Issue.record("Expected .toolResult")
            return
        }
        #expect(result.output.isEmpty)
        #expect(result.callId == "call-4")
    }

    @Test
    func assistantMessageWithInlineToolCallBlockEmitsCallBeforeMessage() {
        // When the content array places the tool call before the final
        // text, the parser must keep that order so the UI shows the tool
        // row before the completed assistant response.
        let raw = #"""
        {"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"read_file","arguments":{"path":"/tmp/a.txt"}},{"type":"text","text":"Got it"}]}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 2)
        guard case .toolCall(let call, let callIndex) = events[0] else {
            Issue.record("Expected .toolCall at index 0, got \(events[0])")
            return
        }
        guard case .message(let message, let messageIndex) = events[1] else {
            Issue.record("Expected .message at index 1, got \(events[1])")
            return
        }
        #expect(message.role == .assistant)
        #expect(message.content == [.text("Got it")])
        #expect(messageIndex == 0)
        #expect(callIndex == 0)
        #expect(call.id == "call-1")
        if case .function(_, let name, let arguments) = call {
            #expect(name == "read_file")
            #expect(arguments.contains("\"path\":\"/tmp/a.txt\""))
        } else {
            Issue.record("Expected function-style tool call")
        }
    }

    @Test
    func assistantMessageWithMultipleToolCallsEmitsEachAsEvent() {
        let raw = #"""
        {"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"toolCall","id":"call-1","name":"read_file","arguments":{"path":"/tmp/a"}},{"type":"toolCall","id":"call-2","name":"read_file","arguments":{"path":"/tmp/b"}}]}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 3)
        #expect({
            if case .message = events[0] { return true }
            return false
        }())
        #expect({
            if case .toolCall(let a, _) = events[1] { return a.id == "call-1" }
            return false
        }())
        #expect({
            if case .toolCall(let b, _) = events[2] { return b.id == "call-2" }
            return false
        }())
    }

    @Test
    func assistantMessagePreservesThinkingBetweenToolCalls() {
        let raw = #"""
        {"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"first"},{"type":"toolCall","id":"call-1","name":"read_file","arguments":{"path":"/tmp/a"}},{"type":"thinking","thinking":"second"},{"type":"toolCall","id":"call-2","name":"grep","arguments":{"pattern":"TODO"}},{"type":"thinking","thinking":"third"},{"type":"text","text":"done"}]}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 5)
        #expect({
            if case .message(let message, _) = events[0] { return message.content.contains(where: {
                if case .thinking(let text, _) = $0 { return text == "first" }
                return false
            }) }
            return false
        }())
        #expect({
            if case .toolCall(let call, _) = events[1] { return call.id == "call-1" }
            return false
        }())
        #expect({
            if case .message(let message, _) = events[2] { return message.content.contains(where: {
                if case .thinking(let text, _) = $0 { return text == "second" }
                return false
            }) }
            return false
        }())
        #expect({
            if case .toolCall(let call, _) = events[3] { return call.id == "call-2" }
            return false
        }())
        #expect({
            if case .message(let message, _) = events[4] {
                let texts = message.content.compactMap { block -> String? in
                    if case .text(let text) = block { return text }
                    return nil
                }
                let thinkings = message.content.compactMap { block -> String? in
                    if case .thinking(let text, _) = block { return text }
                    return nil
                }
                return texts == ["done"] && thinkings == ["third"]
            }
            return false
        }())
    }

    @Test
    func emptyThinkingFallsBackToSummaryTextInSignature() {
        let raw = #"""
        {"type":"message","id":"m2","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","thinkingSignature":"{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"**Considering context display**\\n\\nShow the max clearly.\"}]}"},{"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"/tmp/a"}}]}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 2)
        guard case .message(let message, _) = events[0] else {
            Issue.record("Expected .message before tool call")
            return
        }
        let thinking = message.content.compactMap { block -> String? in
            if case .thinking(let text, _) = block { return text }
            return nil
        }
        #expect(thinking == ["**Considering context display**\n\nShow the max clearly."])
    }

    @Test
    func emptyThinkingWithoutSummaryStillStaysHidden() {
        let raw = #"""
        {"type":"message","id":"m3","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","thinkingSignature":"{\"id\":\"rs_2\",\"type\":\"reasoning\",\"summary\":[]}"},{"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"/tmp/a"}}]}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        #expect({
            if case .toolCall(let call, _) = events[0] { return call.id == "call-1" }
            return false
        }())
    }

    @Test
    func nonAssistantMessagesDoNotEmitInlineToolCallEvents() {
        // A user message that happens to contain a `toolCall` block in
        // its content array (it never should, but be defensive) must not
        // be reinterpreted as a tool call. Only assistant messages do.
        let raw = #"""
        {"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"hi"},{"type":"toolCall","id":"call-x","name":"oops","arguments":{}}]}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        guard case .message(let message, _) = events[0] else {
            Issue.record("Expected a single .message")
            return
        }
        #expect(message.role == .user)
    }

    @Test
    func toolResultMessageFollowedByAssistantMessagePreservesOrder() {
        // The full sequence on the wire: assistant decides to call a
        // tool, the tool returns, then the assistant continues. The
        // parser must keep the line ordering intact so the chat view
        // shows the timeline correctly.
        let lines = [
            #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"toolCall","id":"call-1","name":"read_file","arguments":{"path":"/tmp/a"}}]}}"#,
            #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read_file","content":"hello","isError":false}}"#,
            #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"text","text":"got it"}]}}"#
        ]

        let events = SessionEventParser.parse(lines: lines)

        #expect(events.count == 4)
        #expect({
            if case .message(let m, _) = events[0] { return m.id == "a1" }
            return false
        }())
        #expect({
            if case .toolCall(let c, _) = events[1] { return c.id == "call-1" }
            return false
        }())
        #expect({
            if case .toolResult(let r, _) = events[2] { return r.callId == "call-1" }
            return false
        }())
        #expect({
            if case .message(let m, _) = events[3] { return m.id == "a2" }
            return false
        }())
    }

    @Test
    func legacyTopLevelToolResultShapeIsStillSupported() {
        // Some older Pi dumps (and third-party tools) emit a top-level
        // `type: "tool_result"` line. Keep that path working so
        // historical sessions keep rendering correctly.
        let raw = #"""
        {"type":"tool_result","id":"legacy-1","toolCallId":"call-1","content":"legacy output","isError":false}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        guard case .toolResult(let result, _) = events[0] else {
            Issue.record("Expected .toolResult")
            return
        }
        #expect(result.callId == "call-1")
        #expect(result.output == "legacy output")
    }

    @Test
    func legacyTopLevelToolResultShapeCapturesToolName() {
        let raw = #"""
        {"type":"tool_result","id":"legacy-2","toolCallId":"call-2","toolName":"bash","content":"$ ls","isError":true}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        guard case .toolResult(let result, _) = events.first else {
            Issue.record("Expected .toolResult")
            return
        }
        #expect(result.toolName == "bash")
        #expect(result.isError == true)
    }

    @Test
    func legacyTopLevelToolUseShapeIsStillSupported() {
        // The legacy `type: "tool_use"` shape (Anthropic-style) lives
        // alongside the newer `type: "tool_call"` shape. Both must keep
        // working for users with old session files.
        let raw = #"""
        {"type":"tool_use","id":"call-1","name":"read_file","input":{"path":"/tmp/legacy"}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        guard case .toolCall(let call, _) = events[0] else {
            Issue.record("Expected .toolCall")
            return
        }
        if case .function(_, let name, let arguments) = call {
            #expect(name == "read_file")
            #expect(arguments.contains("\"path\":\"/tmp/legacy\""))
        } else {
            Issue.record("Expected function-style call")
        }
    }

    @Test
    func legacyTopLevelToolCallShapeIsStillSupported() {
        let raw = #"""
        {"type":"tool_call","id":"call-2","name":"grep","arguments":{"pattern":"TODO","path":"/src"}}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        guard case .toolCall(let call, _) = events[0] else {
            Issue.record("Expected .toolCall")
            return
        }
        if case .function(_, let name, let arguments) = call {
            #expect(name == "grep")
            #expect(arguments.contains("\"pattern\":\"TODO\""))
        } else {
            Issue.record("Expected function-style call")
        }
    }

    @Test
    func unknownEventTypeBecomesOtherEvent() {
        // Bookkeeping entries (`label`, `branch_summary`, custom
        // extensions) should not be dropped on the floor — the chat
        // view renders them as a compact "event · label" row.
        let raw = #"""
        {"type":"label","id":"l1","targetId":"m1","label":"checkpoint"}
        """#

        let events = SessionEventParser.parse(lines: [raw])

        #expect(events.count == 1)
        guard case .other(let type, _) = events[0] else {
            Issue.record("Expected .other")
            return
        }
        #expect(type == "label")
    }

    @Test
    func decodeAllReturnsEveryEventForALineIncludingToolCallBlocks() {
        // `decodeAll` is the entry point used by `parse(lines:)` and
        // must surface every event a single line encodes.
        let raw = #"""
        {"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/x"}}]}}
        """#

        let events = SessionEventParser.decodeAll(line: raw, at: 7)

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.lineIndex == 7 })
        #expect({
            if case .message = events[0] { return true }
            return false
        }())
        #expect({
            if case .toolCall(let c, _) = events[1] { return c.id == "c1" }
            return false
        }())
    }

    @Test
    func decodeReturnsFirstEventPerLineForLiveTail() {
        // `decode` is used by the live tail path; it must still return
        // a single event so existing callers don't have to change.
        let raw = #"""
        {"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/x"}}]}}
        """#

        let event = SessionEventParser.decode(line: raw, at: 11)

        #expect(event?.lineIndex == 11)
        #expect({
            if case .message = event { return true }
            return false
        }())
    }
}
