package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestV2UploadDoesNotExposeDaemonCachePath(t *testing.T) {
	store := newAttachmentTestStore(t)
	srv := &server{agentDir: filepath.Dir(store.localRoot), attachments: store}
	body := new(bytes.Buffer)
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "note.txt")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte("hello"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/uploads", body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	request.Header.Set("X-Pi-Attachment-Protocol", "2")
	response := httptest.NewRecorder()
	srv.handleUploads(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("upload: %d %s", response.Code, response.Body.String())
	}
	var result map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if _, hasPath := result["path"]; hasPath {
		t.Fatalf("v2 response exposed local path: %#v", result)
	}
	if _, ok := result["id"].(string); !ok {
		t.Fatalf("v2 response lacks ID: %#v", result)
	}
}

func TestV2UploadPreservesUnicodeDisplayNameFromSafeHeader(t *testing.T) {
	store := newAttachmentTestStore(t)
	srv := &server{agentDir: filepath.Dir(store.localRoot), attachments: store}
	body := new(bytes.Buffer)
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "________.pdf")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte("pdf"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/uploads", body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	request.Header.Set("X-Pi-Attachment-Protocol", "2")
	request.Header.Set("X-Pi-Attachment-Name-B64", base64.StdEncoding.EncodeToString([]byte("Отчёт 2026.pdf")))
	response := httptest.NewRecorder()
	srv.handleUploads(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("upload: %d %s", response.Code, response.Body.String())
	}
	var result uploadResponse
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.FileName != "Отчёт 2026.pdf" {
		t.Fatalf("fileName = %q", result.FileName)
	}
}

func TestTransportEventHidesInternalAttachmentPath(t *testing.T) {
	store := newAttachmentTestStore(t)
	record, err := store.Upload(context.Background(), strings.NewReader("hello"), "Отчёт.txt", "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	raw := `{"type":"message","id":"user-1","message":{"role":"user","content":[{"type":"text","text":"<file name=\"` + record.LocalPath + `\" attachment-id=\"` + record.ID + `\" attachment-name=\"Отчёт.txt\" attachment-mime=\"text/plain\">hello</file>"}]}}`
	decorated := (&server{attachments: store}).decorateOutboundAttachmentRecord(context.Background(), sessionRecord{}, raw)
	if strings.Contains(decorated, record.LocalPath) {
		t.Fatalf("transport event exposed cache path: %s", decorated)
	}
	if !strings.Contains(decorated, `pi-attachment://`+record.ID+`/Отчёт.txt`) {
		t.Fatalf("transport event lacks opaque URI: %s", decorated)
	}
}

func TestNormalizeOpaqueAttachmentTagsRepairsMalformedLegacyNameAttribute(t *testing.T) {
	id := "att_0123456789abcdef0123456789abcdef"
	input := `<file name="/tmp/pasted-image.png attachment-id="` + id + `" attachment-name="pasted-image.png" attachment-mime="image/png"></file>`
	output, changed := normalizeOpaqueAttachmentTags(input)
	if !changed {
		t.Fatal("expected malformed attachment tag to be normalized")
	}
	want := `<file name="pi-attachment://` + id + `/pasted-image.png" attachment-id="` + id + `" attachment-name="pasted-image.png" attachment-mime="image/png">`
	if output != want+`</file>` {
		t.Fatalf("normalized tag = %q, want %q", output, want+`</file>`)
	}
}

func TestPromptMarksIDWithoutReplacingToolPath(t *testing.T) {
	store := newAttachmentTestStore(t)
	record, err := store.Upload(context.Background(), strings.NewReader("hello"), "note.txt", "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	payload, err := (&server{agentDir: filepath.Dir(store.localRoot), attachments: store}).buildRPCPromptPayload("read", []attachmentReference{{ID: record.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(payload.Message, `attachment-id="`+record.ID+`"`) {
		t.Fatalf("missing opaque ID: %q", payload.Message)
	}
	if !strings.Contains(payload.Message, record.LocalPath) {
		t.Fatalf("agent lost local tool path: %q", payload.Message)
	}
}
