package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newAttachmentTestStore(t *testing.T) *attachmentStore {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("PI_APPD_UPLOAD_BACKEND", "local")
	t.Setenv("PI_APPD_ATTACHMENT_LOCAL_DIR", filepath.Join(dir, "uploads"))
	t.Setenv("PI_APPD_ATTACHMENTS_DB", filepath.Join(dir, "uploads.db"))
	store, err := newAttachmentStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func TestAttachmentStorePersistsOpaqueIDAndResolvesIt(t *testing.T) {
	store := newAttachmentTestStore(t)
	record, err := store.Upload(context.Background(), strings.NewReader("hello"), "hello.txt", "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	if !attachmentIDPattern.MatchString(record.ID) {
		t.Fatalf("invalid attachment id %q", record.ID)
	}
	if !strings.Contains(record.LocalPath, record.ID) || !strings.HasSuffix(record.LocalPath, "/hello.txt") {
		t.Fatalf("unexpected local cache path %q", record.LocalPath)
	}
	resolved, err := store.EnsureLocal(context.Background(), record.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.SHA256 == "" || resolved.Size != 5 {
		t.Fatalf("bad metadata: %#v", resolved)
	}
	payload, err := (&server{agentDir: filepath.Dir(store.localRoot), attachments: store}).buildRPCPromptPayload("read this", []attachmentReference{{ID: record.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(payload.Message, "hello") {
		t.Fatalf("payload did not include text file: %q", payload.Message)
	}
}

func TestOutboundAttachmentReferenceIsStoredOncePerMessage(t *testing.T) {
	store := newAttachmentTestStore(t)
	dir := filepath.Dir(store.localRoot)
	artifactDir := filepath.Join(dir, "artifacts")
	if err := os.MkdirAll(artifactDir, 0o700); err != nil {
		t.Fatal(err)
	}
	artifact := filepath.Join(artifactDir, "report.txt")
	if err := os.WriteFile(artifact, []byte("durable outbound file"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := &server{agentDir: dir, attachments: store}
	raw := `{"type":"message_end","id":"assistant-1","message":{"role":"assistant","content":[{"type":"text","text":"Ready: @artifacts/report.txt."}]}}`
	session := sessionRecord{ID: "session-1", WorkingDirectory: dir}

	first := srv.decorateOutboundAttachmentRecord(context.Background(), session, raw)
	if !strings.Contains(first, `attachment-id=\"att_`) || strings.Contains(first, "@artifacts/report.txt") {
		t.Fatalf("decorated record = %s", first)
	}
	second := srv.decorateOutboundAttachmentRecord(context.Background(), session, raw)
	if first != second {
		t.Fatalf("outbound decoration changed across replays:\nfirst: %s\nsecond: %s", first, second)
	}
	var count int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM attachments`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("attachments = %d, want one durable object", count)
	}
}

func TestAttachmentContentRouteOnlyAcceptsOpaqueID(t *testing.T) {
	store := newAttachmentTestStore(t)
	record, err := store.Upload(context.Background(), bytes.NewBufferString("test data"), "report.txt", "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	srv := &server{attachments: store}
	request := httptest.NewRequest(http.MethodGet, "/uploads/"+record.ID+"/content", nil)
	response := httptest.NewRecorder()
	srv.handleUploadSubroutes(response, request)
	if response.Code != http.StatusOK || response.Body.String() != "test data" {
		t.Fatalf("content response: %d %q", response.Code, response.Body.String())
	}
	bad := httptest.NewRecorder()
	srv.handleUploadSubroutes(bad, httptest.NewRequest(http.MethodGet, "/uploads/../../etc/passwd/content", nil))
	if bad.Code != http.StatusNotFound {
		t.Fatalf("path traversal = %d", bad.Code)
	}
}

func TestAttachmentStoreMissingLocalDoesNotClaimAvailabilityWithoutMinIO(t *testing.T) {
	store := newAttachmentTestStore(t)
	record, err := store.Upload(context.Background(), strings.NewReader("test"), "test.txt", "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(record.LocalPath); err != nil {
		t.Fatal(err)
	}
	_, err = store.EnsureLocal(context.Background(), record.ID)
	if !errors.Is(err, errAttachmentNotFound) {
		t.Fatalf("EnsureLocal error = %v, want not found", err)
	}
}

func TestAttachmentUploadResponseIncludesID(t *testing.T) {
	store := newAttachmentTestStore(t)
	srv := &server{agentDir: filepath.Dir(store.localRoot), attachments: store}
	body := new(bytes.Buffer)
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "photo.jpg")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("jpg")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/uploads", body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()
	srv.handleUploads(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("upload = %d %s", response.Code, response.Body.String())
	}
	var decoded uploadResponse
	if err := json.Unmarshal(response.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if !attachmentIDPattern.MatchString(decoded.ID) || decoded.SHA256 == "" {
		t.Fatalf("upload response = %#v", decoded)
	}
}
