package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNormalizeOutboundThinkingRecordConvertsLeadingEnvelope(t *testing.T) {
	raw := `{"type":"message_update","id":"assistant-1","message":{"role":"assistant","content":[{"type":"text","text":"<think>Inspect the client; the reasoning may mention a literal <think> tag.</think>\n\n"},{"type":"toolCall","id":"call-1","name":"bash","arguments":{}}]}}`
	normalized := normalizeOutboundThinkingRecord(raw)
	if strings.Contains(normalized, `</think>`) {
		t.Fatalf("normalized event leaked thinking XML: %s", normalized)
	}

	var event map[string]any
	if err := json.Unmarshal([]byte(normalized), &event); err != nil {
		t.Fatal(err)
	}
	message := event["message"].(map[string]any)
	content := message["content"].([]any)
	if len(content) != 2 {
		t.Fatalf("content count = %d, want 2: %#v", len(content), content)
	}
	thinking := content[0].(map[string]any)
	if thinking["type"] != "thinking" || thinking["thinking"] != "Inspect the client; the reasoning may mention a literal <think> tag." {
		t.Fatalf("thinking block = %#v", thinking)
	}
	if tool := content[1].(map[string]any); tool["type"] != "toolCall" {
		t.Fatalf("tool block = %#v", tool)
	}
}

func TestNormalizeOutboundThinkingRecordPreservesVisibleSuffixAndLiteralProse(t *testing.T) {
	raw := `{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"<think>Check the parser.</think>\n\nFixed."},{"type":"text","text":"Prose can mention <think>example</think> literally."}]}}`
	normalized := normalizeOutboundThinkingRecord(raw)

	var event map[string]any
	if err := json.Unmarshal([]byte(normalized), &event); err != nil {
		t.Fatal(err)
	}
	content := event["message"].(map[string]any)["content"].([]any)
	if len(content) != 3 {
		t.Fatalf("content count = %d, want 3: %#v", len(content), content)
	}
	if got := content[1].(map[string]any)["text"]; got != "\n\nFixed." {
		t.Fatalf("visible suffix = %#v, want \\n\\nFixed.", got)
	}
	if got := content[2].(map[string]any)["text"]; got != "Prose can mention <think>example</think> literally." {
		t.Fatalf("literal prose changed = %#v", got)
	}
}

func TestNormalizeOutboundThinkingRecordLeavesUserAndIncompleteTagsUntouched(t *testing.T) {
	for _, raw := range []string{
		`{"type":"message","message":{"role":"user","content":[{"type":"text","text":"<think>do not reinterpret user text</think>"}]}}`,
		`{"type":"message_update","message":{"role":"assistant","content":[{"type":"text","text":"<think>still streaming"}]}}`,
	} {
		if got := normalizeOutboundThinkingRecord(raw); got != raw {
			t.Fatalf("unexpected normalization:\n got: %s\nwant: %s", got, raw)
		}
	}
}
