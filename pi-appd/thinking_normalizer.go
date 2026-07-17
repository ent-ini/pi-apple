package main

import (
	"encoding/json"
	"regexp"
	"strings"
)

// Pi providers normally persist reasoning in a structured `thinking` block.
// A few compatible providers instead put it in a leading XML envelope inside a
// regular text block. Normalize only that unambiguous wire form before it
// leaves pi-appd, so every Apple client receives the same structured content.
// Session JSONL is intentionally left untouched.
var leadingThinkingEnvelopePattern = regexp.MustCompile(`(?is)^\s*<(?:mm:)?think(?:ing)?\b[^>]*>(.*?)</(?:mm:)?think(?:ing)?[\t\r\n ]*>`)

func normalizeOutboundThinkingRecord(raw string) string {
	var event map[string]any
	if json.Unmarshal([]byte(raw), &event) != nil {
		return raw
	}

	eventType := stringValue(event, "type")
	if eventType != "message" && eventType != "message_update" && eventType != "message_end" {
		return raw
	}
	message, ok := event["message"].(map[string]any)
	if !ok || stringValue(message, "role") != "assistant" {
		return raw
	}
	content, ok := message["content"].([]any)
	if !ok {
		return raw
	}

	normalized := make([]any, 0, len(content)+1)
	changed := false
	for _, rawBlock := range content {
		block, ok := rawBlock.(map[string]any)
		if !ok || stringValue(block, "type") != "text" {
			normalized = append(normalized, rawBlock)
			continue
		}
		text, ok := block["text"].(string)
		if !ok {
			normalized = append(normalized, rawBlock)
			continue
		}

		thinking, visibleText, hasEnvelope := splitLeadingThinkingEnvelope(text)
		if !hasEnvelope {
			normalized = append(normalized, rawBlock)
			continue
		}

		changed = true
		normalized = append(normalized, map[string]any{
			"type":     "thinking",
			"thinking": thinking,
		})
		if strings.TrimSpace(visibleText) != "" {
			visibleBlock := make(map[string]any, len(block))
			for key, value := range block {
				visibleBlock[key] = value
			}
			visibleBlock["text"] = visibleText
			normalized = append(normalized, visibleBlock)
		}
	}

	if !changed {
		return raw
	}
	message["content"] = normalized
	encoded, err := json.Marshal(event)
	if err != nil {
		return raw
	}
	return string(encoded)
}

func splitLeadingThinkingEnvelope(text string) (thinking string, visibleText string, ok bool) {
	match := leadingThinkingEnvelopePattern.FindStringSubmatchIndex(text)
	if match == nil || len(match) < 4 {
		return "", "", false
	}
	thinking = strings.TrimSpace(text[match[2]:match[3]])
	if thinking == "" {
		return "", "", false
	}
	return thinking, text[match[1]:], true
}
