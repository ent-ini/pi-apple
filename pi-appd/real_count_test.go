package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRealSessionFileMessageCountMatchesUserAssistantOnly walks the user's
// real Pi session files and asserts that parseSessionFile's MessageCount
// matches the count of user/assistant message events, never the inflated
// count that includes tool results and bash executions.
func TestRealSessionFileMessageCountMatchesUserAssistantOnly(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	root := filepath.Join(home, ".pi", "agent", "sessions")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Skipf("no sessions dir at %s: %v", root, err)
	}
	if len(entries) == 0 {
		t.Skip("no session files")
	}

	checked := 0
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".jsonl" {
			continue
		}
		path := filepath.Join(root, entry.Name())
		parsed, err := parseSessionFile(path)
		if err != nil {
			continue
		}
		real := countUserAssistantMessages(t, path)
		if parsed.MessageCount != real {
			t.Errorf("%s: MessageCount=%d, want %d (user+assistant only)", entry.Name(), parsed.MessageCount, real)
		}
		checked++
		if checked >= 50 {
			break
		}
	}
	if checked == 0 {
		t.Skip("no parseable session files")
	}
}

func countUserAssistantMessages(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, line := range splitJSONLLines(data) {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		var object map[string]any
		if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
			continue
		}
		if typeValue, _ := object["type"].(string); typeValue != "message" {
			continue
		}
		// Independent role + content extraction: do NOT call messageRole or
		// messageHasUserVisibleContent here, so a bug in the production
		// helpers cannot also poison the expected value and silently make
		// this test pass.
		var (
			role     string
			content  []any
		)
		if inner, ok := object["message"].(map[string]any); ok {
			if r, _ := inner["role"].(string); r != "" {
				role = r
			}
			if blocks, ok := inner["content"].([]any); ok {
				content = blocks
			}
		}
		if role == "" {
			if r, _ := object["role"].(string); r != "" {
				role = r
			}
		}
		if content == nil {
			if blocks, ok := object["content"].([]any); ok {
				content = blocks
			}
		}
		if role != "user" && role != "assistant" {
			continue
		}
		if !contentHasVisibleTextOrImage(content) {
			continue
		}
		count++
	}
	return count
}

func contentHasVisibleTextOrImage(content []any) bool {
	for _, raw := range content {
		block, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		switch blockType, _ := block["type"].(string); blockType {
		case "text":
			if text, _ := block["text"].(string); strings.TrimSpace(text) != "" {
				return true
			}
		case "image":
			return true
		}
	}
	return false
}
