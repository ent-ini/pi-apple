package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

type bufferWriteCloser struct {
	*bytes.Buffer
}

func (w bufferWriteCloser) Close() error { return nil }

func TestSessionRecordLessUsesStableTieBreakers(t *testing.T) {
	now := time.Date(2026, 6, 28, 12, 0, 0, 0, time.UTC)
	older := now.Add(-time.Minute)

	if !sessionRecordLess(sessionRecord{ID: "b", ModifiedAt: now}, sessionRecord{ID: "a", ModifiedAt: older}) {
		t.Fatal("newer session should sort before older session")
	}
	if !sessionRecordLess(sessionRecord{ID: "a", Title: "Alpha", ModifiedAt: now}, sessionRecord{ID: "b", Title: "Beta", ModifiedAt: now}) {
		t.Fatal("equal mtimes should sort by title/id instead of unstable walk order")
	}
}

func TestParseSessionFileUsesLatestSessionInfoFromTail(t *testing.T) {
	var builder strings.Builder
	builder.WriteString("{\"type\":\"session\",\"sessionId\":\"s1\",\"cwd\":\"/tmp/project\"}\n")
	builder.WriteString("{\"type\":\"session_info\",\"name\":\"Old title\"}\n")
	for i := 0; i < 120; i++ {
		builder.WriteString("{\"type\":\"message\",\"id\":\"m")
		builder.WriteString(strconv.Itoa(i))
		builder.WriteString("\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
	}
	builder.WriteString("{\"type\":\"session_info\",\"name\":\"Manual title\"}\n")
	path := writeTempSessionFile(t, builder.String())

	parsed, err := parseSessionFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.DisplayName != "Manual title" {
		t.Fatalf("DisplayName = %q, want latest tail title", parsed.DisplayName)
	}
}

func TestProjectsEqualIncludesLastActivity(t *testing.T) {
	first := time.Date(2026, 6, 28, 12, 0, 0, 0, time.UTC)
	second := first.Add(time.Second)
	left := []projectRecord{{ID: "p", Title: "Project", SessionDirectory: "p", SessionCount: 1, LastActivity: &first}}
	right := []projectRecord{{ID: "p", Title: "Project", SessionDirectory: "p", SessionCount: 1, LastActivity: &second}}

	if projectsEqual(left, right) {
		t.Fatal("project LastActivity changes must trigger a snapshot so clients can reorder projects")
	}
}

func TestBoundedFileModTimeClampsFutureTimestamps(t *testing.T) {
	future := time.Now().Add(time.Hour)
	bounded := boundedFileModTime(future)
	if bounded.After(time.Now().Add(time.Second)) {
		t.Fatalf("boundedFileModTime(%s) = %s, want close to now", future, bounded)
	}
}

func TestIsDetachedClientPromptDetectsNativeAppSourceTags(t *testing.T) {
	tests := []struct {
		name   string
		prompt string
		want   bool
	}{
		{
			name:   "ios source tag with fields",
			prompt: "[source:pi-ios-app type=text session=\"S\"]\nhello",
			want:   true,
		},
		{
			name:   "bare ios source tag",
			prompt: "  [source:pi-ios-app]\nhello",
			want:   true,
		},
		{
			name:   "macos source tag with fields",
			prompt: "[source:pi-macos-app type=text]\nhello",
			want:   true,
		},
		{
			name:   "bare macos source tag",
			prompt: "  [source:pi-macos-app]\nhello",
			want:   true,
		},
		{
			name:   "unknown source tag",
			prompt: "[source:pi-other-app type=text]\nhello",
			want:   false,
		},
		{
			name:   "lookalike source tag",
			prompt: "[source:pi-macos-app-preview type=text]\nhello",
			want:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isDetachedClientPrompt(tt.prompt); got != tt.want {
				t.Fatalf("isDetachedClientPrompt() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestSplitJSONLLinesDropsOnlyTrailingEmptyLine(t *testing.T) {
	if lines := splitJSONLLines([]byte{}); len(lines) != 0 {
		t.Fatalf("empty input = %#v, want []", lines)
	}
	if lines := splitJSONLLines([]byte("a\nb\n")); !reflect.DeepEqual(lines, []string{"a", "b"}) {
		t.Fatalf("trailing newline = %#v", lines)
	}
	if lines := splitJSONLLines([]byte("a\n\n")); !reflect.DeepEqual(lines, []string{"a", ""}) {
		t.Fatalf("intentional blank line = %#v", lines)
	}
}

func TestJSONLLineIndexReadsRangesAndSkipsPartialTail(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}\n{\"type\":\"message\"")
	cache := newJSONLLineIndexCache()
	index, err := cache.load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := index.lineCount(), 2; got != want {
		t.Fatalf("lineCount = %d, want %d", got, want)
	}
	lines, err := index.readRange(1, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(lines, []string{"{\"type\":\"message\",\"id\":\"b\"}"}) {
		t.Fatalf("lines = %#v", lines)
	}
}

func TestJSONLLineIndexKeepsValidTrailingLineWithoutNewline(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}")
	index, err := newJSONLLineIndexCache().load(path)
	if err != nil {
		t.Fatal(err)
	}
	lines, err := index.readRange(0, index.lineCount())
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"{\"type\":\"session\"}", "{\"type\":\"message\",\"id\":\"b\"}"}
	if !reflect.DeepEqual(lines, want) {
		t.Fatalf("lines = %#v, want %#v", lines, want)
	}
}

func TestReadEventRecordsAfterReturnsCatchUpRecords(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}\n{\"type\":\"message\",\"id\":\"c\"}\n")

	records, err := readEventRecordsAfter(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 {
		t.Fatalf("len(records) = %d, want 2", len(records))
	}
	if records[0].Line != 1 || records[0].Raw != "{\"type\":\"message\",\"id\":\"b\"}" || records[1].Line != 2 || records[1].Raw != "{\"type\":\"message\",\"id\":\"c\"}" {
		t.Fatalf("records = %#v", records)
	}
}

func TestReadEventRecordsAfterKeepsValidTrailingLineWithoutNewline(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}")

	records, err := readEventRecordsAfter(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Line != 1 || records[0].Raw != "{\"type\":\"message\",\"id\":\"b\"}" {
		t.Fatalf("records = %#v", records)
	}
}

func TestReadEventRecordsAfterSkipsPartialTrailingLine(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\"")

	records, err := readEventRecordsAfter(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 0 {
		t.Fatalf("records = %#v, want no partial trailing line", records)
	}
}

func TestSessionEventTailerReadsOnlyAppendedCompleteLines(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}\n{\"type\":\"message\"")
	tailer, err := newSessionEventTailer(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	initial, err := tailer.readNewRecords()
	if err != nil {
		t.Fatal(err)
	}
	if len(initial) != 1 || initial[0].Line != 1 {
		t.Fatalf("initial = %#v, want line 1 only", initial)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(",\"id\":\"c\"}\n{\"type\":\"message\",\"id\":\"d\"}\n"); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	appended, err := tailer.readNewRecords()
	if err != nil {
		t.Fatal(err)
	}
	if len(appended) != 2 || appended[0].Line != 2 || appended[1].Line != 3 {
		t.Fatalf("appended = %#v, want lines 2 and 3", appended)
	}
}

func TestReadAllLinesSkipsPartialTrailingLine(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\"")

	lines, err := readAllLines(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(lines, []string{"{\"type\":\"session\"}"}) {
		t.Fatalf("lines = %#v", lines)
	}
}

func TestReadLastLinesTrimsTrailingEmptyLineAndPreservesLineNumbers(t *testing.T) {
	path := writeTempSessionFile(t, "a\nb\nc\n")

	lines, total, err := readLastLines(path, 2)
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 {
		t.Fatalf("total = %d, want 3", total)
	}
	if !reflect.DeepEqual(lines, []string{"b", "c"}) {
		t.Fatalf("lines = %#v", lines)
	}

	all, err := readAllLines(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(all, []string{"a", "b", "c"}) {
		t.Fatalf("all lines = %#v", all)
	}
}

func TestAuthMiddlewareRequiresTokenExceptHealthz(t *testing.T) {
	server := &server{token: ""}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	handler := server.authMiddleware(next)

	healthRequest := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	healthResponse := httptest.NewRecorder()
	handler.ServeHTTP(healthResponse, healthRequest)
	if healthResponse.Code != http.StatusNoContent {
		t.Fatalf("health status = %d, want %d", healthResponse.Code, http.StatusNoContent)
	}

	request := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusUnauthorized)
	}
}

func TestAuthMiddlewareAcceptsBearerToken(t *testing.T) {
	server := &server{token: "secret-token"}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	handler := server.authMiddleware(next)

	request := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusNoContent, response.Body.String())
	}
}

func TestBearerTokenMatches(t *testing.T) {
	if !bearerTokenMatches("Bearer secret-token", "secret-token") {
		t.Fatal("valid bearer token did not match")
	}
	for _, header := range []string{"", "secret-token", "Bearer wrong", "Basic secret-token"} {
		if bearerTokenMatches(header, "secret-token") {
			t.Fatalf("header %q unexpectedly matched", header)
		}
	}
}

func TestHandleFilesRejectsPathsOutsideBrowsableRoots(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	agentDir := filepath.Join(home, ".pi", "agent")
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	server := &server{agentDir: agentDir}
	request := httptest.NewRequest(http.MethodGet, "/files?path="+outside, nil)
	response := httptest.NewRecorder()

	server.handleFiles(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusForbidden, response.Body.String())
	}
}

func TestHandleFilesRejectsSymlinkEscape(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	agentDir := filepath.Join(home, ".pi", "agent")
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	symlinkPath := filepath.Join(home, "escape")
	if err := os.Symlink(outside, symlinkPath); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	t.Setenv("HOME", home)

	server := &server{agentDir: agentDir}
	request := httptest.NewRequest(http.MethodGet, "/files?path="+symlinkPath, nil)
	response := httptest.NewRecorder()

	server.handleFiles(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusForbidden, response.Body.String())
	}
}

func TestHandleFilesOmitsParentOutsideBrowsableRoots(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	agentDir := filepath.Join(home, ".pi", "agent")
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	server := &server{agentDir: agentDir}
	request := httptest.NewRequest(http.MethodGet, "/files?path="+home, nil)
	response := httptest.NewRecorder()

	server.handleFiles(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusOK, response.Body.String())
	}
	var payload fileListResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Parent != "" {
		t.Fatalf("parent = %q, want empty", payload.Parent)
	}
}

func TestHandleUploadsRejectsLargeFiles(t *testing.T) {
	agentDir := t.TempDir()
	server := &server{agentDir: agentDir}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "large.bin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(bytes.Repeat([]byte{'x'}, int(maxUploadFileBytes)+1)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, "/uploads", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()

	server.handleUploads(response, request)
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusRequestEntityTooLarge, response.Body.String())
	}
}

func TestActiveRunDoesNotForceCloseQueuedInputBeforeAgentEnd(t *testing.T) {
	stdin := &bytes.Buffer{}
	run := &activeRun{}
	run.setStdin(bufferWriteCloser{stdin})
	run.markQueuePending(true)
	run.closeIfIdle(run.generation, true)

	run.mu.Lock()
	closedBeforeAgentEnd := run.closed
	run.mu.Unlock()
	if closedBeforeAgentEnd {
		t.Fatal("queued input must not force-close stdin before agent_end")
	}

	run.markAgentEnded()
	run.closeIfIdle(run.generation, true)
	run.mu.Lock()
	closedAfterAgentEnd := run.closed
	run.mu.Unlock()
	if !closedAfterAgentEnd {
		t.Fatal("queued input should be force-closed after agent_end grace expires")
	}
}

func TestSetSessionGeneratingPublishesDelta(t *testing.T) {
	broker := newCatalogBroker()
	updates := make(chan sessionRecord, 4)
	ch := broker.subscribe()
	go func() {
		defer close(updates)
		for event := range ch {
			if event.Type != "session_updated" {
				continue
			}
			var record sessionRecord
			if err := json.Unmarshal(event.Payload, &record); err != nil {
				t.Errorf("invalid session_updated payload: %v", err)
				return
			}
			updates <- record
		}
	}()

	server := &server{
		broker:         broker,
		generatingByID: map[string]bool{},
		sessionsByID: map[string]sessionRecord{
			"session-1": {ID: "session-1", Title: "Busy"},
		},
	}

	server.setSessionGenerating("session-1", true)
	server.setSessionGenerating("session-1", true)

	select {
	case record := <-updates:
		if !record.IsGenerating {
			t.Fatalf("record = %+v, want isGenerating=true", record)
		}
	case <-time.After(time.Second):
		t.Fatal("did not receive session_updated with isGenerating=true")
	}

	server.setSessionGenerating("session-1", false)
	select {
	case record := <-updates:
		if record.IsGenerating {
			t.Fatalf("record = %+v, want isGenerating=false", record)
		}
	case <-time.After(time.Second):
		t.Fatal("did not receive session_updated with isGenerating=false")
	}
}

func TestRefreshCatalogAppliesGeneratingState(t *testing.T) {
	agentDir := t.TempDir()
	sessionsDir := filepath.Join(agentDir, "sessions")
	if err := os.MkdirAll(sessionsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionPath := filepath.Join(sessionsDir, "2026-01-01T00-00-00-000Z_abc123.jsonl")
	if err := os.WriteFile(sessionPath, []byte("{\"type\":\"session\",\"id\":\"abc123\"}\n{\"type\":\"message\",\"id\":\"m1\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	otherPath := filepath.Join(sessionsDir, "2026-01-01T00-00-00-000Z_def456.jsonl")
	if err := os.WriteFile(otherPath, []byte("{\"type\":\"session\",\"id\":\"def456\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := &server{agentDir: agentDir, generatingByID: map[string]bool{"abc123": true}}
	if err := server.refreshCatalog(true); err != nil {
		t.Fatal(err)
	}
	server.mu.RLock()
	defer server.mu.RUnlock()
	for _, record := range server.snapshot.Sessions {
		switch record.ID {
		case "abc123":
			if !record.IsGenerating {
				t.Fatalf("abc123 record = %+v, want isGenerating=true", record)
			}
		case "def456":
			if record.IsGenerating {
				t.Fatalf("def456 record = %+v, want isGenerating=false", record)
			}
		}
	}
}

func TestHandleInputRoutesActiveRunBeforeCatalogLookup(t *testing.T) {
	server := &server{agentDir: t.TempDir()}
	stdin := &bytes.Buffer{}
	run := &activeRun{}
	run.setStdin(bufferWriteCloser{stdin})
	if !server.reserveActiveRun("new-session", run) {
		t.Fatal("failed to reserve active run")
	}
	defer server.unregisterActiveRun("new-session", run)

	body, err := json.Marshal(createSessionRequest{SessionID: "new-session", Prompt: "early input follow-up"})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/input", bytes.NewReader(body))
	response := httptest.NewRecorder()

	server.handleInput(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(stdin.String(), `"streamingBehavior":"steer"`) || !strings.Contains(stdin.String(), "early input follow-up") {
		t.Fatalf("stdin = %q, want steer prompt", stdin.String())
	}
	if !strings.Contains(response.Body.String(), `"type":"output_complete"`) {
		t.Fatalf("response body = %q, want output_complete", response.Body.String())
	}
}

func TestHandleSessionsSendRoutesActiveRunBeforeCatalogLookup(t *testing.T) {
	server := &server{agentDir: t.TempDir()}
	stdin := &bytes.Buffer{}
	run := &activeRun{}
	run.setStdin(bufferWriteCloser{stdin})
	if !server.reserveActiveRun("new-session", run) {
		t.Fatal("failed to reserve active run")
	}
	defer server.unregisterActiveRun("new-session", run)

	body, err := json.Marshal(sendSessionRequest{Prompt: "early follow-up"})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/sessions/new-session/send", bytes.NewReader(body))
	response := httptest.NewRecorder()

	server.handleSessionSubroutes(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(stdin.String(), `"streamingBehavior":"steer"`) || !strings.Contains(stdin.String(), "early follow-up") {
		t.Fatalf("stdin = %q, want steer prompt", stdin.String())
	}
	if !strings.Contains(response.Body.String(), `"type":"output_complete"`) {
		t.Fatalf("response body = %q, want output_complete", response.Body.String())
	}
}

func TestHandleSessionSendRoutesActiveRunToSteer(t *testing.T) {
	agentDir := t.TempDir()
	server := &server{agentDir: agentDir}
	stdin := &bytes.Buffer{}
	run := &activeRun{}
	run.setStdin(bufferWriteCloser{stdin})
	if !server.reserveActiveRun("session-1", run) {
		t.Fatal("failed to reserve active run")
	}
	defer server.unregisterActiveRun("session-1", run)

	body, err := json.Marshal(sendSessionRequest{Prompt: "hello while busy"})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/sessions/session-1/send", bytes.NewReader(body))
	response := httptest.NewRecorder()
	record := sessionRecord{ID: "session-1", FilePath: filepath.Join(agentDir, "session-1.jsonl"), Title: "Busy", WorkingDirectory: agentDir}

	server.handleSessionSend(response, request, record)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", response.Code, response.Body.String())
	}
	if contentType := response.Header().Get("Content-Type"); contentType != "application/x-ndjson" {
		t.Fatalf("content-type = %q, want application/x-ndjson", contentType)
	}
	written := stdin.String()
	if !strings.Contains(written, `"streamingBehavior":"steer"`) || !strings.Contains(written, "hello while busy") {
		t.Fatalf("stdin = %q, want steer prompt", written)
	}
	if !strings.Contains(response.Body.String(), `"type":"output_complete"`) {
		t.Fatalf("response body = %q, want output_complete", response.Body.String())
	}
}

func TestHandleUploadsUsesPrivatePermissions(t *testing.T) {
	agentDir := t.TempDir()
	server := &server{agentDir: agentDir}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "notes.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("secret")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, "/uploads", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()

	server.handleUploads(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusOK, response.Body.String())
	}
	uploadDir := filepath.Join(agentDir, "uploads")
	if info, err := os.Stat(uploadDir); err != nil || info.Mode().Perm() != 0o700 {
		if err != nil {
			t.Fatal(err)
		}
		t.Fatalf("upload dir mode = %o, want 700", info.Mode().Perm())
	}
	var payload uploadResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(payload.Path, uploadDir+string(os.PathSeparator)) {
		t.Fatalf("upload path %q outside %q", payload.Path, uploadDir)
	}
	if info, err := os.Stat(payload.Path); err != nil || info.Mode().Perm() != 0o600 {
		if err != nil {
			t.Fatal(err)
		}
		t.Fatalf("upload file mode = %o, want 600", info.Mode().Perm())
	}
}

func TestBuildRPCPromptPayloadRejectsTooManyAttachments(t *testing.T) {
	attachments := make([]attachmentReference, maxAttachmentCount+1)
	_, err := (&server{agentDir: t.TempDir()}).buildRPCPromptPayload("hello", attachments)
	if err == nil || !strings.Contains(err.Error(), "too many attachments") {
		t.Fatalf("err = %v, want too many attachments", err)
	}
}

func TestBuildRPCPromptPayloadRejectsLargeAttachment(t *testing.T) {
	agentDir := t.TempDir()
	uploadDir := filepath.Join(agentDir, "uploads")
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	largePath := filepath.Join(uploadDir, "large.txt")
	file, err := os.OpenFile(largePath, os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxAttachmentBytes + 1); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	_, err = (&server{agentDir: agentDir}).buildRPCPromptPayload("hello", []attachmentReference{{Path: largePath}})
	if err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("err = %v, want too large", err)
	}
}

func TestSessionFilenameMatchesID(t *testing.T) {
	if !sessionFilenameMatchesID("2026-01-01T00-00-00-000Z_abc123", "abc123") {
		t.Fatal("timestamp_id filename did not match")
	}
	if !sessionFilenameMatchesID("abc123", "abc123") {
		t.Fatal("exact filename did not match")
	}
	for _, base := range []string{"xabc123", "abc123x", "prefix_abc123_suffix", ""} {
		if sessionFilenameMatchesID(base, "abc123") {
			t.Fatalf("base %q unexpectedly matched", base)
		}
	}
}

func TestFindSessionRecordFastRequiresExactParsedID(t *testing.T) {
	agentDir := t.TempDir()
	sessionsDir := filepath.Join(agentDir, "sessions")
	if err := os.MkdirAll(sessionsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	wrongPath := filepath.Join(sessionsDir, "2026-01-01T00-00-00-000Z_target.jsonl")
	if err := os.WriteFile(wrongPath, []byte(`{"type":"session","id":"other","cwd":"/tmp"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if record, ok := findSessionRecordFast(agentDir, "target"); ok {
		t.Fatalf("record = %#v, want no match", record)
	}
}

func TestResolveAttachmentPathsRejectsSymlinkEscape(t *testing.T) {
	agentDir := t.TempDir()
	uploadDir := filepath.Join(agentDir, "uploads")
	outside := filepath.Join(agentDir, "outside")
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	secretPath := filepath.Join(outside, "secret.txt")
	if err := os.WriteFile(secretPath, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkPath := filepath.Join(uploadDir, "link.txt")
	if err := os.Symlink(secretPath, linkPath); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}

	_, err := (&server{agentDir: agentDir}).resolveAttachmentPaths([]attachmentReference{{Path: linkPath}})
	if err == nil || !strings.Contains(err.Error(), "outside uploads") {
		t.Fatalf("err = %v, want outside uploads error", err)
	}
}

func TestLoadDefaultRuntimeFastIncludesEmptyContextUsage(t *testing.T) {
	agentDir := t.TempDir()
	settings := `{"defaultProvider":"opencode-go","defaultModel":"minimax-m3","defaultThinkingLevel":"off"}`
	if err := os.WriteFile(filepath.Join(agentDir, "settings.json"), []byte(settings), 0o600); err != nil {
		t.Fatal(err)
	}

	payload := (&server{agentDir: agentDir}).loadDefaultRuntimeFast(t.TempDir())
	if payload.Runtime.ContextUsage == nil {
		t.Fatal("ContextUsage is nil")
	}
	if payload.Runtime.ContextUsage.Tokens == nil || *payload.Runtime.ContextUsage.Tokens != 0 {
		t.Fatalf("ContextUsage.Tokens = %#v, want 0", payload.Runtime.ContextUsage.Tokens)
	}
	if payload.Runtime.ContextUsage.ContextWindow != 512000 {
		t.Fatalf("ContextWindow = %d, want 512000", payload.Runtime.ContextUsage.ContextWindow)
	}
	if payload.Runtime.ContextUsage.Percent == nil || *payload.Runtime.ContextUsage.Percent != 0 {
		t.Fatalf("Percent = %#v, want 0", payload.Runtime.ContextUsage.Percent)
	}
}

func writeTempSessionFile(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestResolveFileReferencePathUsesBaseForRelativeChatRefs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	workspace := filepath.Join(home, "ai-agent", "workspace")
	if err := os.MkdirAll(filepath.Join(workspace, "wiki-memory"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(workspace, "wiki-memory", "note.md")
	if err := os.WriteFile(target, []byte("ok"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := &server{agentDir: filepath.Join(home, ".pi", "agent")}

	resolved, err := srv.resolveFileReferencePath("wiki-memory/note.md", workspace)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != target {
		t.Fatalf("resolved = %q, want %q", resolved, target)
	}
}

func TestResolveFileReferencePathRejectsOutsideBrowsableRoots(t *testing.T) {
	home := t.TempDir()
	outside := t.TempDir()
	t.Setenv("HOME", home)
	outsideFile := filepath.Join(outside, "secret.txt")
	if err := os.WriteFile(outsideFile, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := &server{agentDir: filepath.Join(home, ".pi", "agent")}

	if _, err := srv.resolveFileReferencePath(outsideFile, ""); err == nil {
		t.Fatal("expected outside path to be rejected")
	}
}
