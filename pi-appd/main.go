package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/fsnotify/fsnotify"
)

var sharedJSONLLineIndexes = newJSONLLineIndexCache()

const (
	maxUploadBodyBytes        int64 = 64 << 20
	maxUploadFileBytes        int64 = 32 << 20
	maxAttachmentCount              = 16
	maxAttachmentBytes        int64 = 32 << 20
	maxImageAttachmentBytes   int64 = 10 << 20
	maxDownloadFileBytes      int64 = 64 << 20
	maxTranscriptionFileBytes int64 = 32 << 20
	serverReadHeaderTimeout         = 5 * time.Second
	serverIdleTimeout               = 60 * time.Second
	rpcCommandTimeout               = 2 * time.Minute
	streamDisconnectKillGrace       = 5 * time.Second
	agentEndCloseGrace              = 500 * time.Millisecond
	queuedInputCloseGrace           = 30 * time.Second
)

type server struct {
	agentDir     string
	token        string
	piExecutable string

	activeRunsMu sync.Mutex
	activeRuns   map[string]*activeRun

	catalogRefreshMu sync.Mutex
	catalogChangeMu  sync.Mutex
	mu               sync.RWMutex
	lastRefresh      time.Time
	snapshot         catalogResponse
	sessionsByID     map[string]sessionRecord

	modelsMu             sync.Mutex
	modelsCache          []rpcModelRecord
	modelsCacheAt        time.Time
	modelsCacheSignature string
	modelsInflight       chan struct{}

	broker      *catalogBroker
	lineIndexes *jsonlLineIndexCache

	generatingMu   sync.Mutex
	generatingByID map[string]bool

	devicesMu        sync.Mutex
	devices          map[string]deviceRecord
	deviceJobs       map[string]*deviceJobRecord
	deviceJobStreams map[string]map[chan deviceJobStreamEvent]struct{}
}

type activeRun struct {
	mu            sync.Mutex
	stdin         io.WriteCloser
	closed        bool
	generation    uint64
	queuePending  bool
	afterAgentEnd bool
}

func (r *activeRun) setStdin(stdin io.WriteCloser) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		_ = stdin.Close()
		return
	}
	r.stdin = stdin
}

func (r *activeRun) write(payload any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return errors.New("active run is closed")
	}
	if r.stdin == nil {
		return errors.New("active run is not ready")
	}
	if err := writeRPCCommand(r.stdin, payload); err != nil {
		return err
	}
	r.generation++
	return nil
}

func (r *activeRun) markQueuePending(pending bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return false
	}
	if r.queuePending != pending {
		r.generation++
	}
	r.queuePending = pending
	return r.afterAgentEnd && !pending
}

func (r *activeRun) markContinuationStarted() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.queuePending = false
	r.afterAgentEnd = false
	r.generation++
}

func (r *activeRun) markAgentEnded() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.afterAgentEnd = true
	r.generation++
}

func (r *activeRun) scheduleCloseAfter(delay time.Duration, forcePending bool) {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	generation := r.generation
	r.mu.Unlock()

	go func() {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		<-timer.C
		r.closeIfIdle(generation, forcePending)
	}()
}

func (r *activeRun) closeIfIdle(generation uint64, forcePending bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.generation != generation {
		return
	}
	if r.queuePending && (!forcePending || !r.afterAgentEnd) {
		return
	}
	if r.stdin != nil {
		_ = r.stdin.Close()
	}
	r.closed = true
}

func (r *activeRun) close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	if r.stdin != nil {
		_ = r.stdin.Close()
	}
	r.closed = true
}

type catalogResponse struct {
	Projects []projectRecord `json:"projects"`
	Sessions []sessionRecord `json:"sessions"`
}

type projectRecord struct {
	ID               string     `json:"id"`
	Title            string     `json:"title"`
	WorkingDirectory string     `json:"workingDirectory,omitempty"`
	SessionDirectory string     `json:"sessionDirectory"`
	SessionCount     int        `json:"sessionCount"`
	LastActivity     *time.Time `json:"lastActivity,omitempty"`
}

type sessionRecord struct {
	ID                 string    `json:"id"`
	FilePath           string    `json:"filePath"`
	ProjectID          string    `json:"projectID"`
	Title              string    `json:"title"`
	WorkingDirectory   string    `json:"workingDirectory,omitempty"`
	MessageCount       int       `json:"messageCount"`
	ModifiedAt         time.Time `json:"modifiedAt"`
	DisplayName        string    `json:"displayName,omitempty"`
	ParentSession      string    `json:"parentSession,omitempty"`
	BranchCount        int       `json:"branchCount"`
	LabelCount         int       `json:"labelCount"`
	BranchSummaryCount int       `json:"branchSummaryCount"`
	LatestModel        string    `json:"latestModel,omitempty"`
	IsGenerating       bool      `json:"isGenerating,omitempty"`
}

type eventsResponse struct {
	Events []rawEventRecord `json:"events"`
	Page   pageRecord       `json:"page"`
}

type rawEventRecord struct {
	Line int    `json:"line"`
	Raw  string `json:"raw"`
}

type pageRecord struct {
	FirstLine     int  `json:"firstLine"`
	LastLine      int  `json:"lastLine"`
	HasMoreBefore bool `json:"hasMoreBefore"`
	HasMoreAfter  bool `json:"hasMoreAfter"`
}

type fileListResponse struct {
	Path   string           `json:"path"`
	Parent string           `json:"parent,omitempty"`
	Items  []fileItemRecord `json:"items"`
}

type fileItemRecord struct {
	Name        string     `json:"name"`
	Path        string     `json:"path"`
	IsDirectory bool       `json:"isDirectory"`
	Size        int64      `json:"size,omitempty"`
	ModifiedAt  *time.Time `json:"modifiedAt,omitempty"`
}

type attachmentReference struct {
	Path     string `json:"path"`
	FileName string `json:"fileName,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
	Size     int64  `json:"size,omitempty"`
}

type createSessionRequest struct {
	SessionID               string                `json:"sessionId"`
	WorkingDirectory        string                `json:"workingDirectory"`
	SessionName             string                `json:"sessionName"`
	IsTemporary             bool                  `json:"isTemporary"`
	Prompt                  string                `json:"prompt"`
	ForkPath                string                `json:"forkPath"`
	Attachments             []attachmentReference `json:"attachments"`
	InitialModelProvider    string                `json:"initialModelProvider"`
	InitialModelID          string                `json:"initialModelId"`
	InitialThinkingLevel    string                `json:"initialThinkingLevel"`
	KeepRunningOnDisconnect bool                  `json:"keepRunningOnDisconnect"`
}

type sendSessionRequest struct {
	Prompt      string                `json:"prompt"`
	Attachments []attachmentReference `json:"attachments"`
}

type setModelRequest struct {
	Provider string `json:"provider"`
	ModelID  string `json:"modelId"`
}

type setThinkingLevelRequest struct {
	Level string `json:"level"`
}

type renameSessionRequest struct {
	Name string `json:"name"`
}

type sessionBoundRecord struct {
	Type             string `json:"type"`
	SessionID        string `json:"sessionId,omitempty"`
	FilePath         string `json:"filePath,omitempty"`
	Title            string `json:"title,omitempty"`
	WorkingDirectory string `json:"workingDirectory,omitempty"`
}

type uploadResponse struct {
	Path     string `json:"path"`
	FileName string `json:"fileName"`
	MimeType string `json:"mimeType,omitempty"`
	Size     int64  `json:"size,omitempty"`
}

type transcriptionResponse struct {
	Text string `json:"text"`
}

type streamErrorRecord struct {
	Type  string `json:"type"`
	Error string `json:"error"`
}

type deviceRecord struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Platform     string    `json:"platform"`
	Capabilities []string  `json:"capabilities"`
	RegisteredAt time.Time `json:"registeredAt"`
	LastSeenAt   time.Time `json:"lastSeenAt"`
}

type deviceRegisterRequest struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Platform     string   `json:"platform"`
	Capabilities []string `json:"capabilities"`
}

type deviceListResponse struct {
	Devices []deviceRecord `json:"devices"`
}

type deviceJobsResponse struct {
	Jobs []deviceJobRecord `json:"jobs"`
}

type deviceJobCreateRequest struct {
	Script         string `json:"script"`
	TimeoutSeconds int    `json:"timeoutSeconds,omitempty"`
}

type deviceJobResultRequest struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
	Logs   []string        `json:"logs,omitempty"`
}

type deviceJobRecord struct {
	ID             string          `json:"id"`
	DeviceID       string          `json:"deviceId"`
	Script         string          `json:"script"`
	TimeoutSeconds int             `json:"timeoutSeconds,omitempty"`
	Status         string          `json:"status"`
	Result         json.RawMessage `json:"result,omitempty"`
	Error          string          `json:"error,omitempty"`
	Logs           []string        `json:"logs,omitempty"`
	CreatedAt      time.Time       `json:"createdAt"`
	StartedAt      *time.Time      `json:"startedAt,omitempty"`
	FinishedAt     *time.Time      `json:"finishedAt,omitempty"`
}

type deviceJobStreamEvent struct {
	Type string          `json:"type"`
	Job  deviceJobRecord `json:"job"`
}

type rpcImageContent struct {
	Type     string `json:"type"`
	Data     string `json:"data"`
	MimeType string `json:"mimeType"`
}

type rpcPromptCommand struct {
	ID                string            `json:"id,omitempty"`
	Type              string            `json:"type"`
	Message           string            `json:"message"`
	Images            []rpcImageContent `json:"images,omitempty"`
	StreamingBehavior string            `json:"streamingBehavior,omitempty"`
}

type rpcGetStateCommand struct {
	ID   string `json:"id,omitempty"`
	Type string `json:"type"`
}

type rpcStateResponse struct {
	Type    string `json:"type"`
	Command string `json:"command"`
	Success bool   `json:"success"`
	Data    *struct {
		SessionFile string          `json:"sessionFile"`
		SessionID   string          `json:"sessionId"`
		SessionName string          `json:"sessionName"`
		Model       *rpcModelRecord `json:"model"`
		Thinking    string          `json:"thinkingLevel"`
	} `json:"data"`
}

type rpcResponseEnvelope struct {
	Type    string          `json:"type"`
	Command string          `json:"command"`
	Success bool            `json:"success"`
	Data    json.RawMessage `json:"data,omitempty"`
	Error   string          `json:"error,omitempty"`
}

type rpcSimpleCommand struct {
	ID                 string `json:"id,omitempty"`
	Type               string `json:"type"`
	Provider           string `json:"provider,omitempty"`
	ModelID            string `json:"modelId,omitempty"`
	Level              string `json:"level,omitempty"`
	Message            string `json:"message,omitempty"`
	Name               string `json:"name,omitempty"`
	CustomInstructions string `json:"customInstructions,omitempty"`
}

type rpcModelRecord struct {
	ID            string `json:"id"`
	Name          string `json:"name,omitempty"`
	Provider      string `json:"provider"`
	Reasoning     bool   `json:"reasoning,omitempty"`
	ContextWindow int    `json:"contextWindow,omitempty"`
}

type rpcAvailableModelsResponse struct {
	Models []rpcModelRecord `json:"models"`
}

type rpcSessionStatsResponse struct {
	Tokens       runtimeTokens        `json:"tokens"`
	ContextUsage *runtimeContextUsage `json:"contextUsage,omitempty"`
}

type runtimeTokens struct {
	Input      int `json:"input"`
	Output     int `json:"output"`
	CacheRead  int `json:"cacheRead"`
	CacheWrite int `json:"cacheWrite"`
	Total      int `json:"total"`
}

type runtimeContextUsage struct {
	Tokens        *int     `json:"tokens,omitempty"`
	ContextWindow int      `json:"contextWindow"`
	Percent       *float64 `json:"percent,omitempty"`
}

type sessionRuntimeResponse struct {
	SessionID     string               `json:"sessionId,omitempty"`
	SessionFile   string               `json:"sessionFile,omitempty"`
	Model         *rpcModelRecord      `json:"model,omitempty"`
	ThinkingLevel string               `json:"thinkingLevel"`
	Tokens        runtimeTokens        `json:"tokens"`
	ContextUsage  *runtimeContextUsage `json:"contextUsage,omitempty"`
}

type sessionDefaultsResponse struct {
	Runtime sessionRuntimeResponse `json:"runtime"`
	Models  []rpcModelRecord       `json:"models"`
}

type agentSettings struct {
	DefaultProvider      string `json:"defaultProvider"`
	DefaultModel         string `json:"defaultModel"`
	DefaultThinkingLevel string `json:"defaultThinkingLevel"`
}

type parsedSession struct {
	ID                 string
	WorkingDirectory   string
	DisplayName        string
	FirstUserMessage   string
	MessageCount       int
	ParentSession      string
	BranchCount        int
	LabelCount         int
	BranchSummaryCount int
	LatestModel        string
}

type statusRecorder struct {
	http.ResponseWriter
	statusCode int
}

func (r *statusRecorder) WriteHeader(statusCode int) {
	r.statusCode = statusCode
	r.ResponseWriter.WriteHeader(statusCode)
}

// Flush forwards to the underlying ResponseWriter when it supports flushing.
// This lets streaming handlers (SSE, NDJSON) work through the logging middleware.
func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func main() {
	agentDir := getenvDefault("PI_APPD_AGENT_DIR", "~/.pi/agent")
	addr := getenvDefault("PI_APPD_ADDR", "127.0.0.1:8787")
	token := strings.TrimSpace(os.Getenv("PI_APPD_TOKEN"))
	piExecutable := getenvDefault("PI_APPD_PI_EXECUTABLE", "pi")

	srv := &server{
		agentDir:         expandHome(agentDir),
		token:            token,
		piExecutable:     piExecutable,
		sessionsByID:     map[string]sessionRecord{},
		broker:           newCatalogBroker(),
		lineIndexes:      sharedJSONLLineIndexes,
		devices:          map[string]deviceRecord{},
		deviceJobs:       map[string]*deviceJobRecord{},
		deviceJobStreams: map[string]map[chan deviceJobStreamEvent]struct{}{},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealthz)
	mux.HandleFunc("/models", srv.handleModels)
	mux.HandleFunc("/runtime/defaults", srv.handleRuntimeDefaults)
	mux.HandleFunc("/input", srv.handleInput)
	mux.HandleFunc("/sessions", srv.handleSessions)
	mux.HandleFunc("/sessions/", srv.handleSessionSubroutes)
	mux.HandleFunc("/files", srv.handleFiles)
	mux.HandleFunc("/file", srv.handleFile)
	mux.HandleFunc("/uploads", srv.handleUploads)
	mux.HandleFunc("/transcribe", srv.handleTranscribe)
	mux.HandleFunc("/devices", srv.handleDevices)
	mux.HandleFunc("/devices/", srv.handleDeviceSubroutes)
	mux.HandleFunc("/device-jobs/", srv.handleDeviceJobSubroutes)

	go srv.watchCatalog()

	log.Printf("pi-appd listening on %s (agentDir=%s)", addr, srv.agentDir)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.loggingMiddleware(srv.authMiddleware(mux)),
		ReadHeaderTimeout: serverReadHeaderTimeout,
		IdleTimeout:       serverIdleTimeout,
	}
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func (s *server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		if s.token == "" || !bearerTokenMatches(r.Header.Get("Authorization"), s.token) {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		writer := &statusRecorder{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(writer, r)
		log.Printf("%s %s -> %d (%s) from %s", r.Method, r.URL.Path, writer.statusCode, time.Since(started).Round(time.Millisecond), r.RemoteAddr)
	})
}

func bearerTokenMatches(header string, token string) bool {
	header = strings.TrimSpace(header)
	if token == "" || !strings.HasPrefix(header, "Bearer ") {
		return false
	}
	candidate := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(token)) == 1
}

func (s *server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	cwd := strings.TrimSpace(r.URL.Query().Get("cwd"))
	if cwd == "" {
		cwd = os.Getenv("HOME")
	}
	models, err := s.loadAvailableModels(expandHome(cwd))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, rpcAvailableModelsResponse{Models: models})
}

func (s *server) handleRuntimeDefaults(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	cwd := strings.TrimSpace(r.URL.Query().Get("cwd"))
	if cwd == "" {
		cwd = os.Getenv("HOME")
	}
	payload := s.loadDefaultRuntimeFast(expandHome(cwd))
	writeJSON(w, http.StatusOK, payload)
}

func (s *server) handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/sessions" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		if err := s.refreshCatalogIfNeeded(); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.mu.RLock()
		defer s.mu.RUnlock()
		writeJSON(w, http.StatusOK, s.snapshot)
	case http.MethodPost:
		s.handleCreateSession(w, r)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *server) handleSessionSubroutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/sessions/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	// /sessions/stream is a top-level subroute and does not require a session lookup.
	if parts[0] == "stream" && (len(parts) == 1 || parts[1] == "") {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionsStream(w, r)
		return
	}
	sessionID := parts[0]
	if len(parts) == 2 && parts[1] == "abort" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionAbort(w, r, sessionID)
		return
	}
	if len(parts) == 2 && parts[1] == "steer" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionSteer(w, r, sessionID)
		return
	}
	if len(parts) == 2 && parts[1] == "send" && s.activeRunForSession(sessionID) != nil {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionSendToActiveRun(w, r, sessionID, nil)
		return
	}
	record, ok, err := s.lookupSessionRecord(sessionID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "unknown session")
		return
	}
	if len(parts) == 1 {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		writeJSON(w, http.StatusOK, record)
		return
	}
	if len(parts) == 2 && parts[1] == "events" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionEvents(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "compact" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionCompact(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "stream" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionEventStream(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "send" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionSend(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "name" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionRename(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "runtime" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionRuntime(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "models" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionModels(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "model" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionSetModel(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "thinking" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionSetThinkingLevel(w, r, record)
		return
	}
	if len(parts) == 3 && parts[1] == "thinking" && parts[2] == "cycle" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionCycleThinking(w, r, record)
		return
	}
	writeError(w, http.StatusNotFound, "not found")
}

func (s *server) handleSessionRuntime(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	runtime, err := s.loadSessionRuntime(record)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, runtime)
}

func (s *server) handleSessionModels(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	cwd := firstNonBlank(strings.TrimSpace(record.WorkingDirectory), filepath.Dir(record.FilePath), os.Getenv("HOME"))
	models, err := s.loadAvailableModels(expandHome(cwd))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, rpcAvailableModelsResponse{Models: models})
}

func (s *server) handleSessionSetModel(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	var request setModelRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	request.Provider = strings.TrimSpace(request.Provider)
	request.ModelID = strings.TrimSpace(request.ModelID)
	if request.Provider == "" || request.ModelID == "" {
		writeError(w, http.StatusBadRequest, "provider and modelId are required")
		return
	}
	_, err := s.runPiRPCCommands(record, []any{
		rpcSimpleCommand{Type: "set_model", Provider: request.Provider, ModelID: request.ModelID},
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	runtime, err := s.loadSessionRuntime(record)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.publishRuntime(record, runtime)
	writeJSON(w, http.StatusOK, runtime)
}

func (s *server) handleSessionSetThinkingLevel(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	var request setThinkingLevelRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	request.Level = strings.TrimSpace(strings.ToLower(request.Level))
	if request.Level == "none" {
		request.Level = "off"
	}
	if !isValidThinkingLevel(request.Level) {
		writeError(w, http.StatusBadRequest, "invalid thinking level")
		return
	}
	_, err := s.runPiRPCCommands(record, []any{
		rpcSimpleCommand{Type: "set_thinking_level", Level: request.Level},
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	runtime, err := s.loadSessionRuntime(record)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.publishRuntime(record, runtime)
	writeJSON(w, http.StatusOK, runtime)
}

func (s *server) handleSessionCycleThinking(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	_, err := s.runPiRPCCommands(record, []any{
		rpcSimpleCommand{Type: "cycle_thinking_level"},
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	runtime, err := s.loadSessionRuntime(record)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.publishRuntime(record, runtime)
	writeJSON(w, http.StatusOK, runtime)
}

func (s *server) publishRuntime(record sessionRecord, runtime sessionRuntimeResponse) {
	payload := map[string]any{
		"sessionId": firstNonBlank(runtime.SessionID, record.ID),
		"runtime":   runtime,
	}
	s.broker.publishRuntimeChanged(payload)
}

func isValidThinkingLevel(level string) bool {
	switch level {
	case "off", "minimal", "low", "medium", "high", "xhigh":
		return true
	default:
		return false
	}
}

func (s *server) handleSessionEvents(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	before, hasBefore, err := optionalInt(r.URL.Query().Get("before"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid before")
		return
	}
	after, hasAfter, err := optionalInt(r.URL.Query().Get("after"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid after")
		return
	}
	limit := 0
	if !hasBefore && !hasAfter {
		limit = 60
	}
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 0 {
			writeError(w, http.StatusBadRequest, "invalid limit")
			return
		}
	}

	lineIndex, err := s.loadJSONLLineIndex(record.FilePath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	totalLines := lineIndex.lineCount()

	start, end := 0, totalLines
	hasMoreBefore, hasMoreAfter := false, false
	if !hasBefore && !hasAfter {
		if limit > 0 && totalLines > limit {
			start = totalLines - limit
		}
		hasMoreBefore = start > 0
	} else if hasBefore {
		if before < 0 {
			before = 0
		}
		if before > totalLines {
			before = totalLines
		}
		end = before
		if limit > 0 && end-limit > 0 {
			start = end - limit
		} else {
			start = 0
		}
		hasMoreBefore = start > 0
		hasMoreAfter = end < totalLines
	} else if hasAfter {
		if after < -1 {
			after = -1
		}
		start = after + 1
		if start < 0 {
			start = 0
		}
		if start > totalLines {
			start = totalLines
		}
		end = totalLines
		if limit > 0 && start+limit < end {
			end = start + limit
			hasMoreAfter = true
		}
		hasMoreBefore = start > 0
	} else if limit > 0 && limit < totalLines {
		start = totalLines - limit
		hasMoreBefore = start > 0
	}

	lines, err := lineIndex.readRange(start, end)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	events := make([]rawEventRecord, 0, len(lines))
	for i, line := range lines {
		events = append(events, rawEventRecord{Line: start + i, Raw: line})
	}
	page := pageRecord{HasMoreBefore: hasMoreBefore, HasMoreAfter: hasMoreAfter}
	if len(events) > 0 {
		page.FirstLine = events[0].Line
		page.LastLine = events[len(events)-1].Line
	}
	writeJSON(w, http.StatusOK, eventsResponse{Events: events, Page: page})
}

func (s *server) handleSessionEventStream(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	after, hasAfter, err := optionalInt(r.URL.Query().Get("after"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid after")
		return
	}
	if !hasAfter {
		after = -1
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		writeSSEError(w, flusher, err.Error())
		return
	}
	defer watcher.Close()

	sessionPath := filepath.Clean(record.FilePath)
	resolvedSessionPath := sessionPath
	if resolved, err := filepath.EvalSymlinks(sessionPath); err == nil {
		resolvedSessionPath = filepath.Clean(resolved)
	}
	if err := watcher.Add(filepath.Dir(resolvedSessionPath)); err != nil {
		writeSSEError(w, flusher, err.Error())
		return
	}

	tailer, err := newSessionEventTailer(record.FilePath, after)
	if err != nil {
		writeSSEError(w, flusher, err.Error())
		return
	}
	sendAfterCursor := func() bool {
		records, err := tailer.readNewRecords()
		if err != nil {
			writeSSEError(w, flusher, err.Error())
			return false
		}
		for _, event := range records {
			if !writeSSE(w, flusher, "event", event) {
				return false
			}
		}
		return true
	}
	if !sendAfterCursor() {
		return
	}

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()

	debounce := time.NewTimer(time.Hour)
	if !debounce.Stop() {
		<-debounce.C
	}
	defer debounce.Stop()
	scheduleRead := func() {
		if !debounce.Stop() {
			select {
			case <-debounce.C:
			default:
			}
		}
		debounce.Reset(100 * time.Millisecond)
	}

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			if !sendAfterCursor() {
				return
			}
			if _, err := io.WriteString(w, ": ping\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case <-debounce.C:
			if !sendAfterCursor() {
				return
			}
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			eventPath := filepath.Clean(event.Name)
			if eventPath != sessionPath && eventPath != resolvedSessionPath {
				continue
			}
			if event.Op&(fsnotify.Remove|fsnotify.Rename) != 0 {
				writeSSEError(w, flusher, "session file was removed")
				return
			}
			if event.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Chmod) != 0 {
				scheduleRead()
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			writeSSEError(w, flusher, err.Error())
			return
		}
	}
}

type sessionEventTailer struct {
	path   string
	cursor int
	offset int64
}

func newSessionEventTailer(path string, after int) (*sessionEventTailer, error) {
	index, err := sharedJSONLLineIndexes.load(path)
	if err != nil {
		return nil, err
	}
	lineCount := index.lineCount()
	tailer := &sessionEventTailer{path: path, cursor: after, offset: index.tailOffset}
	start := after + 1
	if start < 0 {
		start = 0
	}
	if start > lineCount {
		start = lineCount
	}
	// Rewind offset to the start of the first unsent complete line so the
	// initial readNewRecords call can emit catch-up records through the same
	// append-tail path used for live updates.
	if start < lineCount {
		tailer.offset = index.starts[start]
		tailer.cursor = start - 1
	} else {
		tailer.cursor = lineCount - 1
	}
	return tailer, nil
}

func (t *sessionEventTailer) readNewRecords() ([]rawEventRecord, error) {
	file, err := os.Open(t.path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() < t.offset {
		// File was truncated/rotated. Fall back to a fresh full catch-up from the
		// current cursor, then continue tailing from the new complete offset.
		data, err := os.ReadFile(t.path)
		if err != nil {
			return nil, err
		}
		lines, offset := splitCompleteJSONLLinesWithOffset(data)
		t.offset = offset
		records := recordsAfterLines(lines, t.cursor)
		if len(records) > 0 {
			t.cursor = records[len(records)-1].Line
		}
		return records, nil
	}
	if _, err := file.Seek(t.offset, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, err
	}
	lines, consumed := splitCompleteJSONLLinesWithOffset(data)
	if consumed > 0 {
		t.offset += consumed
	}
	records := make([]rawEventRecord, 0, len(lines))
	for _, line := range lines {
		t.cursor++
		records = append(records, rawEventRecord{Line: t.cursor, Raw: line})
	}
	return records, nil
}

func readEventRecordsAfter(path string, after int) ([]rawEventRecord, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines, _ := splitCompleteJSONLLinesWithOffset(data)
	return recordsAfterLines(lines, after), nil
}

func recordsAfterLines(lines []string, after int) []rawEventRecord {
	start := after + 1
	if start < 0 {
		start = 0
	}
	if start > len(lines) {
		start = len(lines)
	}
	records := make([]rawEventRecord, 0, len(lines)-start)
	for i := start; i < len(lines); i++ {
		records = append(records, rawEventRecord{Line: i, Raw: lines[i]})
	}
	return records
}

func (s *server) handleInput(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var request createSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if sessionID := strings.TrimSpace(request.SessionID); sessionID != "" {
		s.handleSessionInputRequest(w, r.Context().Done(), sessionID, request)
		return
	}
	s.handleCreateSessionRequest(w, r, request)
}

func (s *server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var request createSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	s.handleCreateSessionRequest(w, r, request)
}

func (s *server) handleCreateSessionRequest(w http.ResponseWriter, r *http.Request, request createSessionRequest) {
	if request.IsTemporary {
		writeError(w, http.StatusBadRequest, "temporary sessions are not supported yet")
		return
	}
	prompt := strings.TrimSpace(request.Prompt)
	if prompt == "" {
		writeError(w, http.StatusBadRequest, "prompt is required")
		return
	}
	cwd := strings.TrimSpace(request.WorkingDirectory)
	if cwd == "" {
		cwd = os.Getenv("HOME")
	}
	cwd = expandHome(cwd)

	rpcPrompt, err := s.buildRPCPromptPayload(prompt, request.Attachments)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	args := []string{"--mode", "rpc"}
	if strings.TrimSpace(request.ForkPath) != "" {
		args = append(args, "--fork", expandHome(request.ForkPath))
	} else if strings.TrimSpace(request.SessionName) != "" {
		args = append(args, "--name", strings.TrimSpace(request.SessionName))
	}
	settings := s.loadAgentSettings()
	prePromptCommands := make([]any, 0, 2)
	provider := strings.TrimSpace(request.InitialModelProvider)
	modelID := strings.TrimSpace(request.InitialModelID)
	if provider == "" && modelID == "" {
		provider = strings.TrimSpace(settings.DefaultProvider)
		modelID = strings.TrimSpace(settings.DefaultModel)
	}
	if provider != "" {
		if modelID == "" {
			writeError(w, http.StatusBadRequest, "initialModelId is required when initialModelProvider is set")
			return
		}
		prePromptCommands = append(prePromptCommands, rpcSimpleCommand{Type: "set_model", Provider: provider, ModelID: modelID})
	}
	level := strings.TrimSpace(strings.ToLower(request.InitialThinkingLevel))
	if level == "" {
		level = strings.TrimSpace(strings.ToLower(settings.DefaultThinkingLevel))
	}
	if level != "" {
		if level == "none" {
			level = "off"
		}
		if !isValidThinkingLevel(level) {
			writeError(w, http.StatusBadRequest, "invalid initial thinking level")
			return
		}
		prePromptCommands = append(prePromptCommands, rpcSimpleCommand{Type: "set_thinking_level", Level: level})
	}

	title := firstNonBlank(strings.TrimSpace(request.SessionName), filepath.Base(cwd), "Pi")
	requestDone := r.Context().Done()
	if request.KeepRunningOnDisconnect || isDetachedClientPrompt(request.Prompt) {
		requestDone = nil
	}
	if err := s.streamPiRPCCommand(w, requestDone, cwd, args, rpcPrompt, prePromptCommands, nil, title, cwd); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
}

func (s *server) handleSessionSend(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	var request sendSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	s.handleSessionSendRequest(w, r.Context().Done(), record, request)
}

func (s *server) handleSessionInputRequest(w http.ResponseWriter, requestDone <-chan struct{}, sessionID string, request createSessionRequest) {
	if request.KeepRunningOnDisconnect || isDetachedClientPrompt(request.Prompt) {
		requestDone = nil
	}
	if s.activeRunForSession(sessionID) != nil {
		s.handleSessionSendToActiveRunFromRequest(w, sessionID, sendSessionRequest{Prompt: request.Prompt, Attachments: request.Attachments}, nil)
		return
	}
	record, ok, err := s.lookupSessionRecord(sessionID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "unknown session")
		return
	}
	s.handleSessionSendRequest(w, requestDone, record, sendSessionRequest{Prompt: request.Prompt, Attachments: request.Attachments})
}

func (s *server) handleSessionSendRequest(w http.ResponseWriter, requestDone <-chan struct{}, record sessionRecord, request sendSessionRequest) {
	prompt := strings.TrimSpace(request.Prompt)
	if prompt == "" {
		writeError(w, http.StatusBadRequest, "prompt is required")
		return
	}
	if fresh, ok := findSessionRecordFast(s.agentDir, record.ID); ok {
		record = fresh
	}
	binding := &sessionBoundRecord{
		Type:             "session_bound",
		SessionID:        record.ID,
		FilePath:         record.FilePath,
		Title:            record.Title,
		WorkingDirectory: record.WorkingDirectory,
	}
	cwd := firstNonBlank(strings.TrimSpace(record.WorkingDirectory), filepath.Dir(record.FilePath), os.Getenv("HOME"))
	rpcPrompt, err := s.buildRPCPromptPayload(prompt, request.Attachments)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if s.activeRunForSession(record.ID) != nil {
		if err := s.routePromptToActiveRun(record.ID, rpcPrompt); err != nil {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		writeQueuedSteerAccepted(w, binding)
		return
	}
	args := []string{"--mode", "rpc", "--session", record.FilePath}
	if err := s.streamPiRPCCommand(w, requestDone, cwd, args, rpcPrompt, nil, binding, record.Title, record.WorkingDirectory); err != nil {
		if strings.Contains(err.Error(), "active run") {
			if routeErr := s.routePromptToActiveRun(record.ID, rpcPrompt); routeErr == nil {
				writeQueuedSteerAccepted(w, binding)
				return
			}
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
}

func (s *server) handleSessionRename(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	var request renameSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	name := strings.TrimSpace(request.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	if _, err := s.runPiRPCCommands(record, []any{rpcSimpleCommand{Type: "set_session_name", Name: name}}); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.handleCatalogChange()
	updated, ok := findSessionRecordFast(s.agentDir, record.ID)
	if !ok {
		updated = record
		updated.Title = name
		updated.DisplayName = name
	}
	writeJSON(w, http.StatusOK, updated)
}

func (s *server) handleSessionAbort(w http.ResponseWriter, r *http.Request, sessionID string) {
	run := s.activeRunForSession(sessionID)
	if run == nil {
		writeError(w, http.StatusConflict, "session is not currently streaming")
		return
	}
	if err := run.write(rpcSimpleCommand{ID: "pi-appd-abort", Type: "abort"}); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleSessionSteer(w http.ResponseWriter, r *http.Request, sessionID string) {
	rpcPrompt, ok := s.decodeSendPrompt(w, r)
	if !ok {
		return
	}
	if err := s.routePromptToActiveRun(sessionID, rpcPrompt); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleSessionSendToActiveRun(w http.ResponseWriter, r *http.Request, sessionID string, binding *sessionBoundRecord) {
	rpcPrompt, ok := s.decodeSendPrompt(w, r)
	if !ok {
		return
	}
	if err := s.routePromptToActiveRun(sessionID, rpcPrompt); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeQueuedSteerAccepted(w, binding)
}

func (s *server) handleSessionSendToActiveRunFromRequest(w http.ResponseWriter, sessionID string, request sendSessionRequest, binding *sessionBoundRecord) {
	rpcPrompt, ok := s.sendPromptPayload(w, request)
	if !ok {
		return
	}
	if err := s.routePromptToActiveRun(sessionID, rpcPrompt); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeQueuedSteerAccepted(w, binding)
}

func (s *server) decodeSendPrompt(w http.ResponseWriter, r *http.Request) (rpcPromptCommand, bool) {
	var request sendSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return rpcPromptCommand{}, false
	}
	return s.sendPromptPayload(w, request)
}

func (s *server) sendPromptPayload(w http.ResponseWriter, request sendSessionRequest) (rpcPromptCommand, bool) {
	prompt := strings.TrimSpace(request.Prompt)
	if prompt == "" {
		writeError(w, http.StatusBadRequest, "prompt is required")
		return rpcPromptCommand{}, false
	}
	rpcPrompt, err := s.buildRPCPromptPayload(prompt, request.Attachments)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return rpcPromptCommand{}, false
	}
	return rpcPrompt, true
}

func (s *server) routePromptToActiveRun(sessionID string, rpcPrompt rpcPromptCommand) error {
	run := s.activeRunForSession(sessionID)
	if run == nil {
		return errors.New("session is not currently streaming")
	}
	rpcPrompt.ID = "pi-appd-steer"
	rpcPrompt.StreamingBehavior = "steer"
	if err := run.write(rpcPrompt); err != nil {
		return err
	}
	// A successfully written steer can be delivered after the current agent_end.
	// Keep the RPC stdin open long enough for Pi to consume the queued steering
	// message and start the continuation turn, but still force-close if Pi never
	// resumes and no further output arrives.
	run.markQueuePending(true)
	run.scheduleCloseAfter(queuedInputCloseGrace, true)
	return nil
}

func writeQueuedSteerAccepted(w http.ResponseWriter, binding *sessionBoundRecord) {
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)
	if binding != nil {
		writeNDJSON(w, binding)
	}
	writeNDJSON(w, map[string]any{"type": "output_complete"})
	if flusher != nil {
		flusher.Flush()
	}
}

func (s *server) handleSessionCompact(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	var request sendSessionRequest
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&request)
	}
	command := rpcSimpleCommand{Type: "compact", CustomInstructions: strings.TrimSpace(request.Prompt)}
	responses, err := s.runPiRPCCommands(record, []any{command})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if response, ok := responses["compact"]; ok && !response.Success {
		writeError(w, http.StatusInternalServerError, firstNonBlank(strings.TrimSpace(response.Error), "compact failed"))
		return
	}
	s.handleCatalogChange()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleFiles(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	requested := strings.TrimSpace(r.URL.Query().Get("path"))
	if requested == "" {
		requested = os.Getenv("HOME")
		if strings.TrimSpace(requested) == "" {
			requested = s.agentDir
		}
	}
	path, err := s.resolveBrowsablePath(requested)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	items := make([]fileItemRecord, 0, len(entries))
	for _, entry := range entries {
		full := filepath.Join(path, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		modifiedAt := info.ModTime()
		items = append(items, fileItemRecord{
			Name:        entry.Name(),
			Path:        full,
			IsDirectory: entry.IsDir(),
			Size:        info.Size(),
			ModifiedAt:  &modifiedAt,
		})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].IsDirectory != items[j].IsDirectory {
			return items[i].IsDirectory
		}
		return strings.ToLower(items[i].Name) < strings.ToLower(items[j].Name)
	})
	parent := filepath.Dir(path)
	if parent == path || !s.isBrowsablePath(parent) {
		parent = ""
	}
	writeJSON(w, http.StatusOK, fileListResponse{Path: path, Parent: parent, Items: items})
}

func (s *server) handleFile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	requested := strings.TrimSpace(r.URL.Query().Get("path"))
	if requested == "" {
		writeError(w, http.StatusBadRequest, "path is required")
		return
	}
	base := strings.TrimSpace(r.URL.Query().Get("base"))
	path, err := s.resolveFileReferencePath(requested, base)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	info, err := os.Stat(path)
	if err != nil {
		writeError(w, http.StatusBadRequest, "file does not exist")
		return
	}
	if info.IsDir() {
		writeError(w, http.StatusBadRequest, "path is a directory")
		return
	}
	if info.Size() > maxDownloadFileBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "file is too large")
		return
	}
	file, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	defer file.Close()

	contentType := contentTypeForPath(path)
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	w.Header().Set("Content-Disposition", "inline; filename=\""+sanitizeDownloadFilename(filepath.Base(path))+"\"")
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, file)
}

func (s *server) resolveBrowsablePath(requested string) (string, error) {
	return s.resolveFileReferencePath(requested, "")
}

func (s *server) resolveFileReferencePath(requested string, base string) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		return "", errors.New("invalid path")
	}
	candidate := expandHome(requested)
	if !filepath.IsAbs(candidate) {
		base = strings.TrimSpace(base)
		if base != "" {
			candidate = filepath.Join(expandHome(base), candidate)
		}
	}
	abs, err := filepath.Abs(candidate)
	if err != nil {
		return "", errors.New("invalid path")
	}
	realPath, err := filepath.EvalSymlinks(filepath.Clean(abs))
	if err != nil {
		return "", errors.New("path does not exist")
	}
	realPath = filepath.Clean(realPath)
	if !s.isBrowsablePath(realPath) {
		return "", errors.New("path is outside allowed roots")
	}
	return realPath, nil
}

func (s *server) isBrowsablePath(path string) bool {
	path = filepath.Clean(path)
	for _, root := range s.browsableRoots() {
		if pathWithinRoot(path, root) {
			return true
		}
	}
	return false
}

func (s *server) browsableRoots() []string {
	candidates := []string{os.Getenv("HOME"), s.agentDir}
	roots := make([]string, 0, len(candidates))
	seen := map[string]struct{}{}
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		abs, err := filepath.Abs(expandHome(candidate))
		if err != nil {
			continue
		}
		realRoot, err := filepath.EvalSymlinks(filepath.Clean(abs))
		if err != nil {
			continue
		}
		realRoot = filepath.Clean(realRoot)
		if _, ok := seen[realRoot]; ok {
			continue
		}
		seen[realRoot] = struct{}{}
		roots = append(roots, realRoot)
	}
	return roots
}

func pathWithinRoot(path string, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	if path == root {
		return true
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return false
	}
	return true
}

func (s *server) handleUploads(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBodyBytes)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "multipart form is too large")
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "file is required")
		return
	}
	defer file.Close()

	uploadDir := filepath.Join(s.agentDir, "uploads")
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	fileName := sanitizeUploadName(header.Filename)
	targetPath := filepath.Join(uploadDir, uniqueUploadName(fileName))
	targetFile, err := os.OpenFile(targetPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer targetFile.Close()

	limitedFile := &io.LimitedReader{R: file, N: maxUploadFileBytes + 1}
	size, err := io.Copy(targetFile, limitedFile)
	if err != nil {
		_ = os.Remove(targetPath)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if size > maxUploadFileBytes {
		_ = os.Remove(targetPath)
		writeError(w, http.StatusRequestEntityTooLarge, "file is too large")
		return
	}

	writeJSON(w, http.StatusOK, uploadResponse{
		Path:     targetPath,
		FileName: filepath.Base(targetPath),
		MimeType: header.Header.Get("Content-Type"),
		Size:     size,
	})
}

func (s *server) handleTranscribe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	apiKey := strings.TrimSpace(os.Getenv("GROQ_API_KEY"))
	if apiKey == "" {
		writeError(w, http.StatusServiceUnavailable, "GROQ_API_KEY is not configured on pi-appd")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBodyBytes)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "multipart form is too large")
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "file is required")
		return
	}
	defer file.Close()

	limitedFile := &io.LimitedReader{R: file, N: maxTranscriptionFileBytes + 1}
	fileData, err := io.ReadAll(limitedFile)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if int64(len(fileData)) > maxTranscriptionFileBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "audio file is too large")
		return
	}

	language := strings.TrimSpace(r.FormValue("language"))
	if language == "" {
		language = "ru"
	}
	model := strings.TrimSpace(r.FormValue("model"))
	if model == "" {
		model = "whisper-large-v3"
	}

	text, err := transcribeWithGroq(r.Context(), apiKey, model, language, sanitizeUploadName(header.Filename), header.Header.Get("Content-Type"), fileData)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, transcriptionResponse{Text: text})
}

func transcribeWithGroq(ctx context.Context, apiKey string, model string, language string, fileName string, contentType string, fileData []byte) (string, error) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("model", model); err != nil {
		return "", err
	}
	if language != "" {
		if err := writer.WriteField("language", language); err != nil {
			return "", err
		}
	}
	if contentType == "" {
		contentType = contentTypeForPath(fileName)
	}
	part, err := writer.CreatePart(textprotoMIMEHeader(map[string]string{
		"Content-Disposition": "form-data; name=\"file\"; filename=\"" + sanitizeDownloadFilename(fileName) + "\"",
		"Content-Type":        contentType,
	}))
	if err != nil {
		return "", err
	}
	if _, err := part.Write(fileData); err != nil {
		return "", err
	}
	if err := writer.Close(); err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.groq.com/openai/v1/audio/transcriptions", &body)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message := strings.TrimSpace(string(respBody))
		if message == "" {
			message = resp.Status
		}
		return "", errors.New("Groq transcription failed: " + message)
	}
	var decoded transcriptionResponse
	if err := json.Unmarshal(respBody, &decoded); err != nil {
		return "", err
	}
	decoded.Text = strings.TrimSpace(decoded.Text)
	if decoded.Text == "" {
		return "", errors.New("Groq returned an empty transcript")
	}
	return decoded.Text, nil
}

func textprotoMIMEHeader(values map[string]string) textproto.MIMEHeader {
	header := textproto.MIMEHeader{}
	for key, value := range values {
		header.Set(key, value)
	}
	return header
}

func isDetachedClientPrompt(prompt string) bool {
	trimmed := strings.TrimSpace(prompt)
	return strings.HasPrefix(trimmed, "[source:pi-ios-app ") || strings.HasPrefix(trimmed, "[source:pi-ios-app]")
}

func (s *server) buildRPCPromptPayload(prompt string, attachments []attachmentReference) (rpcPromptCommand, error) {
	if len(attachments) > maxAttachmentCount {
		return rpcPromptCommand{}, errors.New("too many attachments")
	}
	prefix := strings.Builder{}
	images := make([]rpcImageContent, 0, len(attachments))
	resolved, err := s.resolveAttachmentPaths(attachments)
	if err != nil {
		return rpcPromptCommand{}, err
	}

	for _, attachment := range resolved {
		info, statErr := os.Stat(attachment.Path)
		if statErr != nil {
			return rpcPromptCommand{}, errors.New("attachment file does not exist")
		}
		if info.Size() > maxAttachmentBytes {
			return rpcPromptCommand{}, errors.New("attachment is too large")
		}
		isImageAttachment := strings.HasPrefix(strings.ToLower(strings.TrimSpace(attachment.MimeType)), "image/")
		if isImageAttachment && info.Size() > maxImageAttachmentBytes {
			return rpcPromptCommand{}, errors.New("image attachment is too large")
		}
		data, readErr := os.ReadFile(attachment.Path)
		if readErr != nil {
			return rpcPromptCommand{}, errors.New("attachment file does not exist")
		}

		if isImageAttachment {
			images = append(images, rpcImageContent{
				Type:     "image",
				Data:     base64.StdEncoding.EncodeToString(data),
				MimeType: attachment.MimeType,
			})
			prefix.WriteString("<file name=\"")
			prefix.WriteString(xmlEscape(attachment.Path))
			prefix.WriteString("\"></file>\n")
			continue
		}

		if len(data) <= 200000 && utf8.Valid(data) && !bytes.Contains(data, []byte{0}) {
			prefix.WriteString("<file name=\"")
			prefix.WriteString(xmlEscape(attachment.Path))
			prefix.WriteString("\">\n")
			prefix.Write(data)
			prefix.WriteString("\n</file>\n")
			continue
		}

		fallback := "[Binary file attached: " + firstNonBlank(attachment.FileName, filepath.Base(attachment.Path), "attachment") + "]"
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(attachment.MimeType)), "audio/") {
			fallback = "[Audio attachment: " + firstNonBlank(attachment.FileName, filepath.Base(attachment.Path), "audio") + "]"
		}
		prefix.WriteString("<file name=\"")
		prefix.WriteString(xmlEscape(attachment.Path))
		prefix.WriteString("\">")
		prefix.WriteString(xmlEscape(fallback))
		prefix.WriteString("</file>\n")
	}

	message := prompt
	if prefix.Len() > 0 {
		message = prefix.String() + "\n" + prompt
	}
	return rpcPromptCommand{
		ID:      "pi-appd-prompt",
		Type:    "prompt",
		Message: message,
		Images:  images,
	}, nil
}

func (s *server) resolveAttachmentPaths(attachments []attachmentReference) ([]attachmentReference, error) {
	if len(attachments) == 0 {
		return nil, nil
	}
	allowedRoot := filepath.Clean(filepath.Join(s.agentDir, "uploads"))
	if realRoot, err := filepath.EvalSymlinks(allowedRoot); err == nil {
		allowedRoot = filepath.Clean(realRoot)
	}
	resolved := make([]attachmentReference, 0, len(attachments))
	for _, attachment := range attachments {
		pathValue, err := filepath.Abs(expandHome(strings.TrimSpace(attachment.Path)))
		if err != nil {
			return nil, errors.New("invalid attachment path")
		}
		pathValue = filepath.Clean(pathValue)
		if realPath, err := filepath.EvalSymlinks(pathValue); err == nil {
			pathValue = filepath.Clean(realPath)
		}
		if !pathWithinRoot(pathValue, allowedRoot) {
			return nil, errors.New("attachment path is outside uploads directory")
		}
		if _, err := os.Stat(pathValue); err != nil {
			return nil, errors.New("attachment file does not exist")
		}
		attachment.Path = pathValue
		resolved = append(resolved, attachment)
	}
	return resolved, nil
}

func (s *server) reserveActiveRun(sessionID string, run *activeRun) bool {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" || run == nil {
		return false
	}
	s.activeRunsMu.Lock()
	defer s.activeRunsMu.Unlock()
	if s.activeRuns == nil {
		s.activeRuns = map[string]*activeRun{}
	}
	if existing := s.activeRuns[sessionID]; existing != nil && existing != run {
		return false
	}
	s.activeRuns[sessionID] = run
	s.setSessionGeneratingLocked(sessionID, true)
	return true
}

func (s *server) unregisterActiveRun(sessionID string, run *activeRun) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" || run == nil {
		return
	}
	s.activeRunsMu.Lock()
	if current := s.activeRuns[sessionID]; current == run {
		delete(s.activeRuns, sessionID)
	}
	s.activeRunsMu.Unlock()
	s.setSessionGenerating(sessionID, false)
}

// setSessionGenerating records the active-run state for the catalog and
// publishes a per-session `session_updated` delta so the client list can
// show a typing/generating indicator without waiting for a file change.
// Pass `generating=false` only when the active run for this session is the
// one being torn down; cross-call interference is guarded by the global
// activeRuns registry.
func (s *server) setSessionGenerating(sessionID string, generating bool) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return
	}
	if !generating && s.activeRunForSession(sessionID) != nil {
		return
	}
	s.generatingMu.Lock()
	previous, hasPrevious := s.generatingByID[sessionID]
	if s.generatingByID == nil {
		s.generatingByID = map[string]bool{}
	}
	if hasPrevious && previous == generating {
		s.generatingMu.Unlock()
		return
	}
	if generating {
		s.generatingByID[sessionID] = true
	} else {
		delete(s.generatingByID, sessionID)
	}
	s.generatingMu.Unlock()
	if hasPrevious && previous == generating {
		return
	}
	s.publishSessionGeneratingDelta(sessionID, generating)
}

func (s *server) setSessionGeneratingLocked(sessionID string, generating bool) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return
	}
	s.generatingMu.Lock()
	previous, hasPrevious := s.generatingByID[sessionID]
	if s.generatingByID == nil {
		s.generatingByID = map[string]bool{}
	}
	if generating {
		s.generatingByID[sessionID] = true
	} else if hasPrevious {
		delete(s.generatingByID, sessionID)
	}
	s.generatingMu.Unlock()
	if hasPrevious && previous == generating {
		return
	}
	go s.publishSessionGeneratingDelta(sessionID, generating)
}

func (s *server) publishSessionGeneratingDelta(sessionID string, generating bool) {
	if s.broker == nil {
		return
	}
	s.mu.RLock()
	record, ok := s.sessionsByID[sessionID]
	s.mu.RUnlock()
	if !ok {
		return
	}
	record.IsGenerating = generating
	s.broker.publishSessionUpdated(record)
}

// applyGeneratingState overlays the in-memory active-run flags onto the
// freshly built catalog snapshot so SSE full snapshots also reflect
// typing state without needing a subsequent `session_updated` for the
// same transition.
func (s *server) applyGeneratingState(snapshot *catalogResponse) {
	s.generatingMu.Lock()
	defer s.generatingMu.Unlock()
	if len(s.generatingByID) == 0 {
		return
	}
	for i := range snapshot.Sessions {
		if s.generatingByID[snapshot.Sessions[i].ID] {
			snapshot.Sessions[i].IsGenerating = true
		}
	}
}

func (s *server) activeRunForSession(sessionID string) *activeRun {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return nil
	}
	s.activeRunsMu.Lock()
	defer s.activeRunsMu.Unlock()
	return s.activeRuns[sessionID]
}

func (s *server) streamPiRPCCommand(
	w http.ResponseWriter,
	requestDone <-chan struct{},
	cwd string,
	args []string,
	prompt rpcPromptCommand,
	prePromptCommands []any,
	binding *sessionBoundRecord,
	fallbackTitle string,
	fallbackWorkingDirectory string,
) error {
	run := &activeRun{}
	activeSessionID := ""
	registerBinding := func(candidate *sessionBoundRecord) bool {
		if candidate == nil || strings.TrimSpace(candidate.SessionID) == "" {
			return true
		}
		nextSessionID := strings.TrimSpace(candidate.SessionID)
		if activeSessionID == nextSessionID {
			return true
		}
		if !s.reserveActiveRun(nextSessionID, run) {
			return false
		}
		if activeSessionID != "" {
			s.unregisterActiveRun(activeSessionID, run)
		}
		activeSessionID = nextSessionID
		return true
	}
	if binding != nil && !registerBinding(binding) {
		return errors.New("session already has an active run")
	}
	releaseActiveRun := func() {
		if activeSessionID != "" {
			s.unregisterActiveRun(activeSessionID, run)
			activeSessionID = ""
		}
	}
	defer releaseActiveRun()

	cmd := exec.Command(s.piExecutable, args...)
	cmd.Dir = expandHome(cwd)
	cmd.Env = append(os.Environ(), "PI_CODING_AGENT_DIR="+s.agentDir)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	run.setStdin(stdin)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	processDone := make(chan struct{})
	var waitOnce sync.Once
	var waitResult error
	waitForCommand := func() error {
		waitOnce.Do(func() {
			waitResult = cmd.Wait()
			close(processDone)
		})
		return waitResult
	}

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)
	if binding != nil {
		writeNDJSON(w, binding)
		if flusher != nil {
			flusher.Flush()
		}
	}

	stderrDone := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(stderr)
		stderrDone <- strings.TrimSpace(string(data))
	}()

	if err := run.write(rpcGetStateCommand{ID: "pi-appd-state", Type: "get_state"}); err != nil {
		writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: err.Error()})
		if flusher != nil {
			flusher.Flush()
		}
		run.close()
		_ = waitForCommand()
		<-stderrDone
		return nil
	}
	for _, command := range prePromptCommands {
		if err := run.write(command); err != nil {
			writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: err.Error()})
			if flusher != nil {
				flusher.Flush()
			}
			run.close()
			_ = waitForCommand()
			<-stderrDone
			return nil
		}
	}
	if err := run.write(prompt); err != nil {
		writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: err.Error()})
		if flusher != nil {
			flusher.Flush()
		}
		run.close()
		_ = waitForCommand()
		<-stderrDone
		return nil
	}

	closeStdin := run.close
	if requestDone != nil {
		go func() {
			<-requestDone
			_ = run.write(rpcSimpleCommand{ID: "pi-appd-client-disconnect-abort", Type: "abort"})
			select {
			case <-processDone:
			case <-time.After(streamDisconnectKillGrace):
				if cmd.Process != nil {
					_ = cmd.Process.Kill()
				}
			}
		}()
	}

	reader := bufio.NewReaderSize(stdout, 64*1024)
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(line) > 0 {
			rawLine := strings.TrimRight(string(line), "\n")
			if binding == nil {
				if parsedBinding, ok := parseRPCStateBindingLine(rawLine, fallbackTitle, fallbackWorkingDirectory); ok {
					binding = &parsedBinding
					if !registerBinding(binding) {
						writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: "session already has an active run"})
						if flusher != nil {
							flusher.Flush()
						}
						closeStdin()
						break
					}
					writeNDJSON(w, binding)
					if flusher != nil {
						flusher.Flush()
					}
					continue
				}
			}
			if isRPCResponseLine(rawLine) {
				if envelope, ok := parseRPCResponseEnvelope(rawLine); ok {
					if !envelope.Success {
						message := strings.TrimSpace(envelope.Error)
						if message == "" {
							message = firstNonBlank(strings.TrimSpace(envelope.Command), "rpc") + " command failed"
						}
						writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: message})
						if flusher != nil {
							flusher.Flush()
						}
						closeStdin()
					} else if envelope.Command == "abort" {
						writeNDJSON(w, map[string]any{"type": "abort"})
						if flusher != nil {
							flusher.Flush()
						}
					}
				}
				continue
			}
			_, _ = io.WriteString(w, rawLine)
			_, _ = io.WriteString(w, "\n")
			if flusher != nil {
				flusher.Flush()
			}
			switch eventType := rpcEventType(rawLine); eventType {
			case "queue_update":
				if pending, ok := rpcQueuePending(rawLine); ok {
					if run.markQueuePending(pending) {
						run.scheduleCloseAfter(agentEndCloseGrace, false)
					}
					if pending {
						run.scheduleCloseAfter(queuedInputCloseGrace, true)
					}
				}
			case "agent_start", "turn_start", "message_start":
				run.markContinuationStarted()
			case "agent_end":
				// Pi can continue after agent_end when a late steering message was
				// queued. Closing stdin immediately sends EOF to rpc-mode and can
				// kill that continuation, so close only after a short idle grace.
				run.markAgentEnded()
				run.scheduleCloseAfter(agentEndCloseGrace, false)
				run.scheduleCloseAfter(queuedInputCloseGrace, true)
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: readErr.Error()})
			if flusher != nil {
				flusher.Flush()
			}
			break
		}
	}

	closeStdin()
	waitErr := waitForCommand()
	stderrText := <-stderrDone
	if waitErr != nil {
		message := stderrText
		if message == "" {
			message = waitErr.Error()
		}
		writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: message})
		if flusher != nil {
			flusher.Flush()
		}
		releaseActiveRun()
		s.handleCatalogChange()
		return nil
	}

	releaseActiveRun()
	s.handleCatalogChange()

	writeNDJSON(w, map[string]any{"type": "output_complete"})
	if flusher != nil {
		flusher.Flush()
	}
	return nil
}
func (s *server) loadSessionRuntime(record sessionRecord) (sessionRuntimeResponse, error) {
	if runtime, err := loadFastSessionRuntime(record); err == nil {
		return runtime, nil
	}
	responses, err := s.runPiRPCCommands(record, []any{
		rpcSimpleCommand{Type: "get_state"},
		rpcSimpleCommand{Type: "get_session_stats"},
	})
	if err != nil {
		return sessionRuntimeResponse{}, err
	}
	return decodeSessionRuntimeResponse(responses)
}

func loadFastSessionRuntime(record sessionRecord) (sessionRuntimeResponse, error) {
	data, err := os.ReadFile(record.FilePath)
	if err != nil {
		return sessionRuntimeResponse{}, err
	}
	runtime := sessionRuntimeResponse{
		SessionID:     record.ID,
		SessionFile:   record.FilePath,
		ThinkingLevel: "off",
	}
	var latestContextTokens *int
	for _, line := range splitJSONLLines(data) {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		var object map[string]any
		if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
			continue
		}
		switch typeValue, _ := object["type"].(string); typeValue {
		case "session":
			if id := stringValue(object, "sessionId", "sessionID", "id"); id != "" {
				runtime.SessionID = id
			}
		case "model_change":
			provider := stringValue(object, "provider")
			modelID := stringValue(object, "modelId", "modelID", "model")
			if provider != "" || modelID != "" {
				runtime.Model = fastModelRecord(provider, modelID)
			}
		case "thinking_level_change":
			if level := stringValue(object, "thinkingLevel", "level"); level != "" {
				runtime.ThinkingLevel = level
			}
		case "message":
			message, _ := object["message"].(map[string]any)
			if message == nil {
				continue
			}
			provider := stringValue(message, "provider")
			modelID := stringValue(message, "model", "modelId", "modelID")
			if provider != "" || modelID != "" {
				runtime.Model = fastModelRecord(provider, modelID)
			}
			usage, _ := message["usage"].(map[string]any)
			if usage == nil {
				continue
			}
			input := intValue(usage, "input")
			output := intValue(usage, "output")
			cacheRead := intValue(usage, "cacheRead")
			cacheWrite := intValue(usage, "cacheWrite")
			total := intValue(usage, "totalTokens", "total")
			if total == 0 {
				total = input + output + cacheRead + cacheWrite
			}
			runtime.Tokens.Input += input
			runtime.Tokens.Output += output
			runtime.Tokens.CacheRead += cacheRead
			runtime.Tokens.CacheWrite += cacheWrite
			runtime.Tokens.Total += total
			if total > 0 {
				contextTokens := total
				latestContextTokens = &contextTokens
			}
		}
	}
	if runtime.Tokens.Total == 0 {
		runtime.Tokens.Total = runtime.Tokens.Input + runtime.Tokens.Output + runtime.Tokens.CacheRead + runtime.Tokens.CacheWrite
	}
	if latestContextTokens != nil || (runtime.Model != nil && runtime.Model.ContextWindow > 0) {
		contextTokens := 0
		if latestContextTokens != nil {
			contextTokens = *latestContextTokens
		} else if runtime.Tokens.Total > 0 {
			contextTokens = runtime.Tokens.Total
		}
		contextUsage := &runtimeContextUsage{Tokens: &contextTokens}
		if runtime.Model != nil && runtime.Model.ContextWindow > 0 {
			contextUsage.ContextWindow = runtime.Model.ContextWindow
			percent := float64(contextTokens) / float64(runtime.Model.ContextWindow) * 100
			contextUsage.Percent = &percent
		}
		runtime.ContextUsage = contextUsage
	}
	if runtime.ThinkingLevel == "" {
		runtime.ThinkingLevel = "off"
	}
	return runtime, nil
}

func (s *server) loadDefaultRuntimeFast(cwd string) sessionDefaultsResponse {
	settings := s.loadAgentSettings()
	provider := firstNonBlank(settings.DefaultProvider, "")
	modelID := firstNonBlank(settings.DefaultModel, "")
	var model *rpcModelRecord
	var contextUsage *runtimeContextUsage
	if provider != "" && modelID != "" {
		model = fastModelRecord(provider, modelID)
		if model.ContextWindow > 0 {
			zeroTokens := 0
			zeroPercent := 0.0
			contextUsage = &runtimeContextUsage{
				Tokens:        &zeroTokens,
				ContextWindow: model.ContextWindow,
				Percent:       &zeroPercent,
			}
		}
	}
	return sessionDefaultsResponse{
		Runtime: sessionRuntimeResponse{
			Model:         model,
			ThinkingLevel: firstNonBlank(settings.DefaultThinkingLevel, "off"),
			Tokens:        runtimeTokens{},
			ContextUsage:  contextUsage,
		},
		Models: s.cachedAvailableModels(),
	}
}

func (s *server) loadAgentSettings() agentSettings {
	var settings agentSettings
	data, err := os.ReadFile(filepath.Join(s.agentDir, "settings.json"))
	if err != nil {
		return settings
	}
	_ = json.Unmarshal(data, &settings)
	return settings
}

const modelsCacheTTL = 6 * time.Hour

func (s *server) cachedAvailableModels() []rpcModelRecord {
	s.modelsMu.Lock()
	defer s.modelsMu.Unlock()
	return cloneModels(s.modelsCache)
}

func (s *server) loadAvailableModels(cwd string) ([]rpcModelRecord, error) {
	signature := s.modelsFilesSignature()
	for {
		s.modelsMu.Lock()
		if len(s.modelsCache) > 0 && s.modelsCacheSignature == signature && time.Since(s.modelsCacheAt) < modelsCacheTTL {
			models := cloneModels(s.modelsCache)
			s.modelsMu.Unlock()
			return models, nil
		}
		if s.modelsInflight != nil {
			inflight := s.modelsInflight
			s.modelsMu.Unlock()
			<-inflight
			continue
		}
		inflight := make(chan struct{})
		s.modelsInflight = inflight
		s.modelsMu.Unlock()

		var models []rpcModelRecord
		var err error
		func() {
			defer func() {
				s.modelsMu.Lock()
				defer s.modelsMu.Unlock()
				defer close(inflight)
				s.modelsInflight = nil
				if err == nil {
					s.modelsCache = cloneModels(models)
					s.modelsCacheAt = time.Now()
					s.modelsCacheSignature = signature
				}
			}()
			models, err = s.fetchAvailableModels(cwd)
		}()
		return models, err
	}
}

func (s *server) fetchAvailableModels(cwd string) ([]rpcModelRecord, error) {
	responses, err := s.runPiRPCCommandsInContext(cwd, "", []any{
		rpcSimpleCommand{Type: "get_available_models"},
	})
	if err != nil {
		return nil, err
	}
	var payload rpcAvailableModelsResponse
	if err := decodeRPCSuccessResponse(responses, "get_available_models", &payload); err != nil {
		return nil, err
	}
	return payload.Models, nil
}

func (s *server) modelsFilesSignature() string {
	parts := make([]string, 0, 3)
	for _, name := range []string{"auth.json", "models.json", "settings.json"} {
		path := filepath.Join(s.agentDir, name)
		info, err := os.Stat(path)
		if err != nil {
			parts = append(parts, name+":missing")
			continue
		}
		parts = append(parts, name+":"+strconv.FormatInt(info.Size(), 10)+":"+strconv.FormatInt(info.ModTime().UnixNano(), 10))
	}
	return strings.Join(parts, "|")
}

func cloneModels(models []rpcModelRecord) []rpcModelRecord {
	out := make([]rpcModelRecord, len(models))
	copy(out, models)
	return out
}

func decodeSessionRuntimeResponse(responses map[string]rpcResponseEnvelope) (sessionRuntimeResponse, error) {
	var state struct {
		SessionFile   string          `json:"sessionFile"`
		SessionID     string          `json:"sessionId"`
		ThinkingLevel string          `json:"thinkingLevel"`
		Model         *rpcModelRecord `json:"model"`
	}
	if err := decodeRPCSuccessResponse(responses, "get_state", &state); err != nil {
		return sessionRuntimeResponse{}, err
	}

	var stats rpcSessionStatsResponse
	if err := decodeRPCSuccessResponse(responses, "get_session_stats", &stats); err != nil {
		return sessionRuntimeResponse{}, err
	}

	return sessionRuntimeResponse{
		SessionID:     state.SessionID,
		SessionFile:   state.SessionFile,
		Model:         state.Model,
		ThinkingLevel: firstNonBlank(state.ThinkingLevel, "off"),
		Tokens:        stats.Tokens,
		ContextUsage:  stats.ContextUsage,
	}, nil
}

func (s *server) runPiRPCCommands(record sessionRecord, commands []any) (map[string]rpcResponseEnvelope, error) {
	cwd := record.WorkingDirectory
	if strings.TrimSpace(cwd) == "" {
		cwd = os.Getenv("HOME")
	}
	return s.runPiRPCCommandsInContext(cwd, record.FilePath, commands)
}

func (s *server) runPiRPCCommandsInContext(cwd string, sessionFile string, commands []any) (map[string]rpcResponseEnvelope, error) {
	args := []string{"--mode", "rpc"}
	if strings.TrimSpace(sessionFile) != "" {
		args = append(args, "--session", sessionFile)
	}
	ctx, cancel := context.WithTimeout(context.Background(), rpcCommandTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.piExecutable, args...)
	cmd.Dir = expandHome(cwd)
	cmd.Env = append(os.Environ(), "PI_CODING_AGENT_DIR="+s.agentDir)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	stderrDone := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(stderr)
		stderrDone <- strings.TrimSpace(string(data))
	}()

	expectedResponses := expectedRPCResponseTypes(commands)
	stdinClosed := false
	for _, command := range commands {
		if err := writeRPCCommand(stdin, command); err != nil {
			_ = stdin.Close()
			stdinClosed = true
			_ = cmd.Wait()
			<-stderrDone
			return nil, err
		}
	}

	responses := make(map[string]rpcResponseEnvelope, len(commands))
	reader := bufio.NewScanner(stdout)
	reader.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for reader.Scan() {
		raw := strings.TrimSpace(reader.Text())
		if raw == "" || !isRPCResponseLine(raw) {
			continue
		}
		var envelope rpcResponseEnvelope
		if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
			continue
		}
		if envelope.Command != "" {
			responses[envelope.Command] = envelope
		}
		if !stdinClosed && allRPCResponsesReceived(responses, expectedResponses) {
			// Keep stdin open while long-running synchronous RPC commands (notably
			// compact) are executing. Closing stdin immediately races RPC-mode
			// shutdown against the command and aborts compaction with
			// "Compaction cancelled". Once all command responses are observed,
			// close stdin to let the one-shot RPC process exit cleanly, then keep
			// draining stdout until EOF so cmd.Wait cannot block on a full pipe.
			_ = stdin.Close()
			stdinClosed = true
		}
	}
	if !stdinClosed {
		_ = stdin.Close()
	}
	if err := reader.Err(); err != nil {
		_ = cmd.Wait()
		<-stderrDone
		return nil, err
	}

	waitErr := cmd.Wait()
	stderrText := <-stderrDone
	if waitErr != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if stderrText != "" {
			return nil, errors.New(stderrText)
		}
		return nil, waitErr
	}

	for _, command := range commands {
		encoded, err := json.Marshal(command)
		if err != nil {
			continue
		}
		var header struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(encoded, &header); err != nil {
			continue
		}
		if header.Type == "" {
			continue
		}
		if _, ok := responses[header.Type]; !ok {
			return nil, errors.New("missing rpc response for " + header.Type)
		}
		if !responses[header.Type].Success {
			return nil, errors.New(firstNonBlank(strings.TrimSpace(responses[header.Type].Error), "rpc command failed: "+header.Type))
		}
	}

	return responses, nil
}

func decodeRPCSuccessResponse(responses map[string]rpcResponseEnvelope, command string, target any) error {
	response, ok := responses[command]
	if !ok {
		return errors.New("missing rpc response for " + command)
	}
	if !response.Success {
		return errors.New(firstNonBlank(strings.TrimSpace(response.Error), "rpc command failed: "+command))
	}
	if target == nil || len(response.Data) == 0 {
		return nil
	}
	if err := json.Unmarshal(response.Data, target); err != nil {
		return err
	}
	return nil
}

func (s *server) invalidateCatalogSnapshot() {
	s.mu.Lock()
	s.lastRefresh = time.Time{}
	s.snapshot = catalogResponse{}
	s.sessionsByID = map[string]sessionRecord{}
	s.mu.Unlock()
}

func expectedRPCResponseTypes(commands []any) []string {
	expected := make([]string, 0, len(commands))
	seen := make(map[string]bool, len(commands))
	for _, command := range commands {
		data, err := json.Marshal(command)
		if err != nil {
			continue
		}
		var header struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &header); err != nil || header.Type == "" || seen[header.Type] {
			continue
		}
		seen[header.Type] = true
		expected = append(expected, header.Type)
	}
	return expected
}

func allRPCResponsesReceived(responses map[string]rpcResponseEnvelope, expected []string) bool {
	if len(expected) == 0 {
		return false
	}
	for _, commandType := range expected {
		if _, ok := responses[commandType]; !ok {
			return false
		}
	}
	return true
}

func writeRPCCommand(w io.Writer, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if _, err := w.Write(data); err != nil {
		return err
	}
	_, err = w.Write([]byte("\n"))
	return err
}

func parseRPCStateBindingLine(raw string, fallbackTitle string, fallbackWorkingDirectory string) (sessionBoundRecord, bool) {
	var response rpcStateResponse
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &response); err != nil {
		return sessionBoundRecord{}, false
	}
	if response.Type != "response" || response.Command != "get_state" || !response.Success || response.Data == nil {
		return sessionBoundRecord{}, false
	}
	return sessionBoundRecord{
		Type:             "session_bound",
		SessionID:        response.Data.SessionID,
		FilePath:         response.Data.SessionFile,
		Title:            firstNonBlank(strings.TrimSpace(response.Data.SessionName), fallbackTitle),
		WorkingDirectory: firstNonBlank(strings.TrimSpace(fallbackWorkingDirectory), os.Getenv("HOME")),
	}, true
}

func isRPCResponseLine(raw string) bool {
	return rpcEventType(raw) == "response"
}

func rpcEventType(raw string) string {
	var object struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &object); err != nil {
		return ""
	}
	return object.Type
}

func rpcQueuePending(raw string) (bool, bool) {
	var object struct {
		Type     string            `json:"type"`
		Steering []json.RawMessage `json:"steering"`
		FollowUp []json.RawMessage `json:"followUp"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &object); err != nil {
		return false, false
	}
	if object.Type != "queue_update" {
		return false, false
	}
	return len(object.Steering)+len(object.FollowUp) > 0, true
}

func parseRPCResponseEnvelope(raw string) (rpcResponseEnvelope, bool) {
	var envelope rpcResponseEnvelope
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &envelope); err != nil {
		return rpcResponseEnvelope{}, false
	}
	if envelope.Type != "response" {
		return rpcResponseEnvelope{}, false
	}
	return envelope, true
}

func parseRPCFailureMessage(raw string) (string, bool) {
	envelope, ok := parseRPCResponseEnvelope(raw)
	if !ok || envelope.Success {
		return "", false
	}
	message := strings.TrimSpace(envelope.Error)
	if message == "" {
		message = firstNonBlank(strings.TrimSpace(envelope.Command), "rpc") + " command failed"
	}
	return message, true
}

func writeNDJSON(w http.ResponseWriter, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, _ = w.Write(data)
	_, _ = w.Write([]byte("\n"))
}

func (s *server) refreshCatalogIfNeeded() error {
	return s.refreshCatalog(false)
}

func (s *server) lookupSessionRecord(sessionID string) (sessionRecord, bool, error) {
	s.mu.RLock()
	record, ok := s.sessionsByID[sessionID]
	s.mu.RUnlock()
	if ok {
		return record, true, nil
	}
	if record, ok := findSessionRecordFast(s.agentDir, sessionID); ok {
		s.mu.Lock()
		if s.sessionsByID == nil {
			s.sessionsByID = map[string]sessionRecord{}
		}
		s.sessionsByID[record.ID] = record
		s.mu.Unlock()
		return record, true, nil
	}
	if err := s.refreshCatalogIfNeeded(); err != nil {
		return sessionRecord{}, false, err
	}
	s.mu.RLock()
	record, ok = s.sessionsByID[sessionID]
	s.mu.RUnlock()
	return record, ok, nil
}

func (s *server) refreshCatalog(force bool) error {
	s.catalogRefreshMu.Lock()
	defer s.catalogRefreshMu.Unlock()

	ttl := s.catalogCacheTTL()
	s.mu.RLock()
	fresh := time.Since(s.lastRefresh) < ttl
	s.mu.RUnlock()
	if fresh && !force {
		return nil
	}

	// Catalog rebuild scans every session file and can take seconds on Orange.
	// Build it outside the global mutex so session event/runtime endpoints can
	// keep reading the previous snapshot instead of queueing behind a writer.
	catalog, byID, err := buildCatalog(s.agentDir)
	if err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.lastRefresh) < ttl && !force {
		return nil
	}
	s.applyGeneratingState(&catalog)
	for id := range byID {
		if record, ok := byID[id]; ok {
			record.IsGenerating = s.isGeneratingLocked(id)
			byID[id] = record
		}
	}
	s.snapshot = catalog
	s.sessionsByID = byID
	s.lastRefresh = time.Now()
	return nil
}

func (s *server) isGeneratingLocked(sessionID string) bool {
	s.generatingMu.Lock()
	defer s.generatingMu.Unlock()
	return s.generatingByID[sessionID]
}

func (s *server) catalogCacheTTL() time.Duration {
	if s.broker != nil && s.broker.subscriberCount() > 0 {
		return 10 * time.Second
	}
	return 30 * time.Second
}

func sessionFilenameMatchesID(base string, sessionID string) bool {
	base = strings.TrimSpace(base)
	sessionID = strings.TrimSpace(sessionID)
	if base == "" || sessionID == "" {
		return false
	}
	return base == sessionID || strings.HasSuffix(base, "_"+sessionID)
}

func findSessionRecordFast(agentDir string, sessionID string) (sessionRecord, bool) {
	root := filepath.Join(agentDir, "sessions")
	var found sessionRecord
	matched := false
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || matched || d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		if !sessionFilenameMatchesID(base, sessionID) {
			return nil
		}
		info, statErr := d.Info()
		if statErr != nil {
			return nil
		}
		parsed, parseErr := parseSessionFile(path)
		if parseErr != nil {
			return nil
		}
		if parsedID := strings.TrimSpace(parsed.ID); parsedID != "" && parsedID != sessionID {
			return nil
		}
		projectID := filepath.Base(filepath.Dir(path))
		if projectID == "sessions" && strings.TrimSpace(parsed.WorkingDirectory) != "" {
			projectID = encodedProjectID(parsed.WorkingDirectory)
		}
		found = sessionRecord{
			ID:                 firstNonBlank(parsed.ID, sessionID, base),
			FilePath:           path,
			ProjectID:          projectID,
			Title:              firstNonBlank(parsed.DisplayName, parsed.FirstUserMessage, base),
			WorkingDirectory:   parsed.WorkingDirectory,
			MessageCount:       parsed.MessageCount,
			ModifiedAt:         boundedFileModTime(info.ModTime()),
			DisplayName:        parsed.DisplayName,
			ParentSession:      parsed.ParentSession,
			BranchCount:        parsed.BranchCount,
			LabelCount:         parsed.LabelCount,
			BranchSummaryCount: parsed.BranchSummaryCount,
			LatestModel:        parsed.LatestModel,
		}
		matched = true
		return filepath.SkipAll
	})
	return found, matched
}

func buildCatalog(agentDir string) (catalogResponse, map[string]sessionRecord, error) {
	root := filepath.Join(agentDir, "sessions")
	sessions := make([]sessionRecord, 0, 64)
	byID := map[string]sessionRecord{}

	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		parsed, err := parseSessionFile(path)
		if err != nil {
			return nil
		}
		projectID := filepath.Base(filepath.Dir(path))
		if projectID == "sessions" && strings.TrimSpace(parsed.WorkingDirectory) != "" {
			projectID = encodedProjectID(parsed.WorkingDirectory)
		}
		title := firstNonBlank(parsed.DisplayName, parsed.FirstUserMessage, strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)))
		record := sessionRecord{
			ID:                 firstNonBlank(parsed.ID, strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))),
			FilePath:           path,
			ProjectID:          projectID,
			Title:              title,
			WorkingDirectory:   parsed.WorkingDirectory,
			MessageCount:       parsed.MessageCount,
			ModifiedAt:         boundedFileModTime(info.ModTime()),
			DisplayName:        parsed.DisplayName,
			ParentSession:      parsed.ParentSession,
			BranchCount:        parsed.BranchCount,
			LabelCount:         parsed.LabelCount,
			BranchSummaryCount: parsed.BranchSummaryCount,
			LatestModel:        parsed.LatestModel,
		}
		sessions = append(sessions, record)
		byID[record.ID] = record
		return nil
	})

	sort.SliceStable(sessions, func(i, j int) bool {
		return sessionRecordLess(sessions[i], sessions[j])
	})
	projects := buildProjects(sessions)
	return catalogResponse{Projects: projects, Sessions: sessions}, byID, nil
}

func buildProjects(sessions []sessionRecord) []projectRecord {
	grouped := map[string][]sessionRecord{}
	for _, session := range sessions {
		grouped[session.ProjectID] = append(grouped[session.ProjectID], session)
	}
	projects := make([]projectRecord, 0, len(grouped))
	for projectID, items := range grouped {
		var last *time.Time
		for _, item := range items {
			if last == nil || item.ModifiedAt.After(*last) {
				value := item.ModifiedAt
				last = &value
			}
		}
		workingDirectory := ""
		if len(items) > 0 {
			workingDirectory = items[0].WorkingDirectory
		}
		projects = append(projects, projectRecord{
			ID:               projectID,
			Title:            projectTitle(projectID, items),
			WorkingDirectory: workingDirectory,
			SessionDirectory: projectID,
			SessionCount:     len(items),
			LastActivity:     last,
		})
	}
	sort.SliceStable(projects, func(i, j int) bool {
		return projectRecordLess(projects[i], projects[j])
	})
	return projects
}

func sessionRecordLess(left, right sessionRecord) bool {
	if !left.ModifiedAt.Equal(right.ModifiedAt) {
		return left.ModifiedAt.After(right.ModifiedAt)
	}
	if !strings.EqualFold(left.Title, right.Title) {
		return strings.ToLower(left.Title) < strings.ToLower(right.Title)
	}
	return left.ID < right.ID
}

func projectRecordLess(left, right projectRecord) bool {
	leftActivity := time.Time{}
	rightActivity := time.Time{}
	if left.LastActivity != nil {
		leftActivity = *left.LastActivity
	}
	if right.LastActivity != nil {
		rightActivity = *right.LastActivity
	}
	if !leftActivity.Equal(rightActivity) {
		return leftActivity.After(rightActivity)
	}
	if !strings.EqualFold(left.Title, right.Title) {
		return strings.ToLower(left.Title) < strings.ToLower(right.Title)
	}
	return left.ID < right.ID
}

func boundedFileModTime(modTime time.Time) time.Time {
	modTime = modTime.UTC()
	now := time.Now().UTC()
	if modTime.After(now) {
		return now
	}
	return modTime
}

func parseSessionFile(path string) (parsedSession, error) {
	// Autonaming usually writes `session_info` after several turns. Tool-heavy
	// early turns can easily exceed 80 JSONL records before that happens, so
	// keep a wider head/tail preview to avoid falling back to the first user
	// message even though the session already has a generated name.
	lines, err := readCatalogPreviewLines(path, 512)
	if err != nil {
		return parsedSession{}, err
	}
	return parseSessionLines(lines), nil
}

func readCatalogPreviewLines(path string, limit int) ([]string, error) {
	head, err := readPreviewLines(path, limit)
	if err != nil {
		return head, err
	}
	tail, total, err := readLastLines(path, limit)
	if err != nil {
		return head, err
	}
	if total <= len(head) {
		return head, nil
	}
	overlap := len(head) + len(tail) - total
	if overlap > 0 {
		if overlap > len(tail) {
			overlap = len(tail)
		}
		tail = tail[overlap:]
	}
	return append(head, tail...), nil
}

func parseSessionLines(lines []string) parsedSession {
	result := parsedSession{}
	childCounts := map[string]int{}
	labelTargets := map[string]struct{}{}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		var object map[string]any
		if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
			continue
		}
		typeValue, _ := object["type"].(string)
		if typeValue == "session" {
			if result.WorkingDirectory == "" {
				result.WorkingDirectory = stringValue(object, "cwd", "workingDirectory")
			}
			if result.ParentSession == "" {
				result.ParentSession = stringValue(object, "parentSession")
			}
			if result.ID == "" {
				result.ID = stringValue(object, "sessionId", "sessionID", "id")
			}
		}
		if typeValue == "session_info" {
			result.DisplayName = stringValue(object, "name", "displayName", "title")
		} else if typeValue == "session" && result.DisplayName == "" {
			result.DisplayName = stringValue(object, "name", "displayName", "title")
		}
		if typeValue == "message" {
			result.MessageCount++
			if parentID, _ := object["parentId"].(string); parentID != "" {
				childCounts[parentID]++
			}
			if message, ok := object["message"].(map[string]any); ok {
				if model := modelDescription(message); model != "" {
					result.LatestModel = model
				}
				if result.FirstUserMessage == "" {
					if role, _ := message["role"].(string); role == "user" {
						result.FirstUserMessage = contentPreview(message["content"])
					}
				}
			} else {
				if model := modelDescription(object); model != "" {
					result.LatestModel = model
				}
				if result.FirstUserMessage == "" {
					if role, _ := object["role"].(string); role == "user" {
						result.FirstUserMessage = contentPreview(object["content"])
					}
				}
			}
		}
		if typeValue == "label" {
			if targetID, _ := object["targetId"].(string); targetID != "" {
				labelTargets[targetID] = struct{}{}
			}
		}
		if typeValue == "branch_summary" {
			result.BranchSummaryCount++
		}
	}
	for _, count := range childCounts {
		if count > 1 {
			result.BranchCount++
		}
	}
	result.LabelCount = len(labelTargets)
	return result
}

func countMessageLines(path string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	buffer := make([]byte, 0, 64*1024)
	scanner.Buffer(buffer, 4*1024*1024)
	count := 0
	for scanner.Scan() {
		trimmed := strings.TrimSpace(scanner.Text())
		if trimmed == "" {
			continue
		}
		var object map[string]any
		if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
			continue
		}
		if typeValue, _ := object["type"].(string); typeValue == "message" {
			count++
		}
	}
	if err := scanner.Err(); err != nil {
		return 0, err
	}
	return count, nil
}

func (s *server) loadJSONLLineIndex(path string) (*jsonlLineIndex, error) {
	if s.lineIndexes == nil {
		s.lineIndexes = sharedJSONLLineIndexes
	}
	return s.lineIndexes.load(path)
}

type jsonlLineIndexCache struct {
	mu      sync.Mutex
	entries map[string]*jsonlLineIndex
}

type jsonlLineIndex struct {
	path       string
	size       int64
	modTime    time.Time
	starts     []int64
	ends       []int64
	tailOffset int64
}

func newJSONLLineIndexCache() *jsonlLineIndexCache {
	return &jsonlLineIndexCache{entries: map[string]*jsonlLineIndex{}}
}

func (c *jsonlLineIndexCache) load(path string) (*jsonlLineIndex, error) {
	stat, err := os.Stat(path)
	if err != nil {
		return nil, err
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if cached := c.entries[path]; cached != nil && cached.size == stat.Size() && cached.modTime.Equal(stat.ModTime()) {
		return cached, nil
	}
	index, err := buildJSONLLineIndex(path, stat)
	if err != nil {
		return nil, err
	}
	c.entries[path] = index
	return index, nil
}

func buildJSONLLineIndex(path string, stat os.FileInfo) (*jsonlLineIndex, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	const chunkSize = 256 * 1024
	buffer := make([]byte, chunkSize)
	starts := make([]int64, 0, 1024)
	ends := make([]int64, 0, 1024)
	var absolute int64
	var currentLineStart int64
	for {
		n, readErr := file.Read(buffer)
		if n > 0 {
			chunk := buffer[:n]
			for i, b := range chunk {
				if b != '\n' {
					continue
				}
				lineEnd := absolute + int64(i)
				starts = append(starts, currentLineStart)
				ends = append(ends, lineEnd)
				currentLineStart = lineEnd + 1
			}
			absolute += int64(n)
		}
		if readErr != nil {
			if readErr == io.EOF {
				break
			}
			return nil, readErr
		}
	}

	// A trailing line without a newline is only visible once it is complete JSON.
	// This matches splitCompleteJSONLLinesWithOffset, which lets freshly written
	// but not-yet-newline-terminated JSONL records show up without exposing a
	// partial write. tailOffset points to where live tailing should resume: EOF
	// for a complete file, or the beginning of the still-partial trailing record.
	tailOffset := stat.Size()
	if currentLineStart < stat.Size() {
		tailLength := stat.Size() - currentLineStart
		tail := make([]byte, tailLength)
		if _, err := file.ReadAt(tail, currentLineStart); err != nil && err != io.EOF {
			return nil, err
		}
		candidate := bytes.TrimSpace(tail)
		if len(candidate) > 0 && json.Valid(candidate) {
			starts = append(starts, currentLineStart)
			ends = append(ends, stat.Size())
		} else {
			tailOffset = currentLineStart
		}
	}

	return &jsonlLineIndex{
		path:       path,
		size:       stat.Size(),
		modTime:    stat.ModTime(),
		starts:     starts,
		ends:       ends,
		tailOffset: tailOffset,
	}, nil
}

func (i *jsonlLineIndex) lineCount() int {
	if i == nil {
		return 0
	}
	return len(i.starts)
}

func (i *jsonlLineIndex) readRange(start, end int) ([]string, error) {
	if i == nil || start >= end {
		return []string{}, nil
	}
	if start < 0 {
		start = 0
	}
	if end > len(i.starts) {
		end = len(i.starts)
	}
	if start >= end {
		return []string{}, nil
	}

	file, err := os.Open(i.path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	lines := make([]string, 0, end-start)
	for lineIndex := start; lineIndex < end; lineIndex++ {
		lineStart := i.starts[lineIndex]
		lineEnd := i.ends[lineIndex]
		if lineEnd < lineStart {
			lineEnd = lineStart
		}
		data := make([]byte, lineEnd-lineStart)
		if len(data) > 0 {
			if _, err := file.ReadAt(data, lineStart); err != nil && err != io.EOF {
				return nil, err
			}
		}
		lines = append(lines, string(data))
	}
	return lines, nil
}

func readAllLines(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return splitCompleteJSONLLines(data), nil
}

func splitCompleteJSONLLines(data []byte) []string {
	lines, _ := splitCompleteJSONLLinesWithOffset(data)
	return lines
}

func splitCompleteJSONLLinesWithOffset(data []byte) ([]string, int64) {
	lines := make([]string, 0, bytes.Count(data, []byte("\n"))+1)
	lineStart := 0
	completeOffset := 0
	for index, b := range data {
		if b != '\n' {
			continue
		}
		lines = append(lines, string(data[lineStart:index]))
		lineStart = index + 1
		completeOffset = lineStart
	}
	if lineStart < len(data) {
		tail := data[lineStart:]
		candidate := strings.TrimSpace(string(tail))
		if candidate != "" && json.Valid([]byte(candidate)) {
			lines = append(lines, string(tail))
			completeOffset = len(data)
		}
	}
	return lines, int64(completeOffset)
}

func splitJSONLLines(data []byte) []string {
	parts := bytes.Split(data, []byte("\n"))
	if len(parts) > 0 && len(parts[len(parts)-1]) == 0 {
		parts = parts[:len(parts)-1]
	}
	lines := make([]string, len(parts))
	for i, part := range parts {
		lines[i] = string(part)
	}
	return lines
}

func readPreviewLines(path string, limit int) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	const chunkSize = 64 * 1024
	buffer := make([]byte, chunkSize)
	pending := make([]byte, 0, chunkSize)
	lines := make([]string, 0, limit)

	for len(lines) < limit {
		n, err := file.Read(buffer)
		if n > 0 {
			pending = append(pending, buffer[:n]...)
			for len(lines) < limit {
				index := bytes.IndexByte(pending, '\n')
				if index < 0 {
					break
				}
				lines = append(lines, string(pending[:index]))
				pending = pending[index+1:]
			}
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			return lines, err
		}
	}
	if len(lines) < limit && len(pending) > 0 {
		lines = append(lines, string(pending))
	}
	return lines, nil
}

func readLastLines(path string, limit int) ([]string, int, error) {
	index, err := sharedJSONLLineIndexes.load(path)
	if err != nil {
		return nil, 0, err
	}
	totalLines := index.lineCount()
	start := 0
	if limit > 0 && totalLines > limit {
		start = totalLines - limit
	}
	lines, err := index.readRange(start, totalLines)
	if err != nil {
		return nil, 0, err
	}
	return lines, totalLines, nil
}

func projectTitle(projectID string, sessions []sessionRecord) string {
	if len(sessions) > 0 && strings.TrimSpace(sessions[0].WorkingDirectory) != "" {
		base := filepath.Base(sessions[0].WorkingDirectory)
		if strings.TrimSpace(base) != "" && base != "." && base != string(filepath.Separator) {
			return base
		}
	}
	return strings.Trim(projectID, "-")
}

func encodedProjectID(workingDirectory string) string {
	clean := filepath.Clean(workingDirectory)
	parts := strings.FieldsFunc(clean, func(r rune) bool { return r == filepath.Separator })
	if len(parts) == 0 {
		return "--root--"
	}
	return "--" + strings.Join(parts, "-") + "--"
}

func stringValue(object map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func intValue(object map[string]any, keys ...string) int {
	for _, key := range keys {
		switch value := object[key].(type) {
		case int:
			return value
		case int64:
			return int(value)
		case float64:
			return int(value)
		case json.Number:
			if parsed, err := value.Int64(); err == nil {
				return int(parsed)
			}
		}
	}
	return 0
}

func fastModelRecord(provider string, modelID string) *rpcModelRecord {
	model := &rpcModelRecord{Provider: provider, ID: modelID, Name: modelID}
	model.ContextWindow = contextWindowForModel(provider, modelID)
	return model
}

func contextWindowForModel(provider string, modelID string) int {
	key := strings.ToLower(provider + "/" + modelID)
	switch {
	case strings.Contains(key, "gpt-5.5"), strings.Contains(key, "gpt-5.4"):
		return 272000
	case strings.Contains(key, "gpt-5.3"):
		return 128000
	case strings.Contains(key, "minimax-m3"):
		return 512000
	case strings.Contains(key, "minimax-m2"):
		return 205000
	case strings.Contains(key, "deepseek-v4"), strings.Contains(key, "qwen3.7-max"), strings.Contains(key, "mimo-v2.5"):
		return 1000000
	case strings.Contains(key, "qwen3.7"), strings.Contains(key, "qwen3.6"), strings.Contains(key, "kimi-k2"):
		return 262000
	case strings.Contains(key, "glm-5"):
		return 203000
	default:
		return 0
	}
}

func modelDescription(object map[string]any) string {
	for _, key := range []string{"model", "modelId", "modelID"} {
		if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func contentPreview(value any) string {
	switch content := value.(type) {
	case string:
		return preview(content)
	case []any:
		for _, block := range content {
			if object, ok := block.(map[string]any); ok {
				if text, ok := object["text"].(string); ok && strings.TrimSpace(text) != "" {
					return preview(text)
				}
			}
		}
	}
	return ""
}

func preview(value string) string {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) <= 80 {
		return trimmed
	}
	return trimmed[:80]
}

func optionalInt(raw string) (int, bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, false, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, false, err
	}
	return value, true, nil
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func (s *server) handleDevices(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/devices" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		s.devicesMu.Lock()
		devices := make([]deviceRecord, 0, len(s.devices))
		for _, device := range s.devices {
			devices = append(devices, device)
		}
		s.devicesMu.Unlock()
		sort.Slice(devices, func(i, j int) bool {
			return devices[i].LastSeenAt.After(devices[j].LastSeenAt)
		})
		writeJSON(w, http.StatusOK, deviceListResponse{Devices: devices})
	case http.MethodPost:
		var req deviceRegisterRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON")
			return
		}
		id := strings.TrimSpace(req.ID)
		if id == "" {
			writeError(w, http.StatusBadRequest, "device id is required")
			return
		}
		now := time.Now().UTC()
		name := strings.TrimSpace(req.Name)
		if name == "" {
			name = id
		}
		platform := strings.TrimSpace(req.Platform)
		if platform == "" {
			platform = "unknown"
		}
		capabilities := append([]string(nil), req.Capabilities...)
		sort.Strings(capabilities)

		s.devicesMu.Lock()
		registeredAt := now
		if existing, ok := s.devices[id]; ok {
			registeredAt = existing.RegisteredAt
		}
		device := deviceRecord{
			ID:           id,
			Name:         name,
			Platform:     platform,
			Capabilities: capabilities,
			RegisteredAt: registeredAt,
			LastSeenAt:   now,
		}
		s.devices[id] = device
		if s.deviceJobStreams[id] == nil {
			s.deviceJobStreams[id] = map[chan deviceJobStreamEvent]struct{}{}
		}
		s.devicesMu.Unlock()
		writeJSON(w, http.StatusOK, device)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *server) handleDeviceSubroutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/devices/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	deviceID := parts[0]
	if len(parts) == 2 && parts[1] == "jobs" {
		switch r.Method {
		case http.MethodGet:
			s.handleListDeviceJobs(w, r, deviceID)
		case http.MethodPost:
			s.handleCreateDeviceJob(w, r, deviceID)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
		return
	}
	if len(parts) == 3 && parts[1] == "jobs" && parts[2] == "stream" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleDeviceJobsStream(w, r, deviceID)
		return
	}
	writeError(w, http.StatusNotFound, "not found")
}

func (s *server) handleListDeviceJobs(w http.ResponseWriter, r *http.Request, deviceID string) {
	s.devicesMu.Lock()
	if _, ok := s.devices[deviceID]; !ok {
		s.devicesMu.Unlock()
		writeError(w, http.StatusNotFound, "unknown device")
		return
	}
	jobs := make([]deviceJobRecord, 0)
	for _, job := range s.deviceJobs {
		if job.DeviceID == deviceID && (job.Status == "queued" || job.Status == "running") {
			jobs = append(jobs, *job)
		}
	}
	if device, ok := s.devices[deviceID]; ok {
		device.LastSeenAt = time.Now().UTC()
		s.devices[deviceID] = device
	}
	s.devicesMu.Unlock()
	sort.Slice(jobs, func(i, j int) bool {
		return jobs[i].CreatedAt.Before(jobs[j].CreatedAt)
	})
	writeJSON(w, http.StatusOK, deviceJobsResponse{Jobs: jobs})
}

func (s *server) handleCreateDeviceJob(w http.ResponseWriter, r *http.Request, deviceID string) {
	var req deviceJobCreateRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	script := strings.TrimSpace(req.Script)
	if script == "" {
		writeError(w, http.StatusBadRequest, "script is required")
		return
	}
	if req.TimeoutSeconds <= 0 {
		req.TimeoutSeconds = 30
	}
	if req.TimeoutSeconds > 300 {
		req.TimeoutSeconds = 300
	}

	s.devicesMu.Lock()
	if _, ok := s.devices[deviceID]; !ok {
		s.devicesMu.Unlock()
		writeError(w, http.StatusNotFound, "unknown device")
		return
	}
	job := &deviceJobRecord{
		ID:             "job-" + strconv.FormatInt(time.Now().UnixNano(), 36),
		DeviceID:       deviceID,
		Script:         script,
		TimeoutSeconds: req.TimeoutSeconds,
		Status:         "queued",
		CreatedAt:      time.Now().UTC(),
	}
	s.deviceJobs[job.ID] = job
	event := deviceJobStreamEvent{Type: "job", Job: *job}
	for ch := range s.deviceJobStreams[deviceID] {
		select {
		case ch <- event:
		default:
		}
	}
	s.devicesMu.Unlock()
	writeJSON(w, http.StatusAccepted, job)
}

func (s *server) handleDeviceJobsStream(w http.ResponseWriter, r *http.Request, deviceID string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch := make(chan deviceJobStreamEvent, 16)
	now := time.Now().UTC()

	s.devicesMu.Lock()
	device, ok := s.devices[deviceID]
	if !ok {
		s.devicesMu.Unlock()
		writeTypedSSE(w, flusher, streamEvent{Type: "error", Payload: mustJSON(map[string]string{"error": "unknown device"})})
		return
	}
	device.LastSeenAt = now
	s.devices[deviceID] = device
	if s.deviceJobStreams[deviceID] == nil {
		s.deviceJobStreams[deviceID] = map[chan deviceJobStreamEvent]struct{}{}
	}
	s.deviceJobStreams[deviceID][ch] = struct{}{}
	pending := make([]deviceJobRecord, 0)
	for _, job := range s.deviceJobs {
		if job.DeviceID == deviceID && job.Status == "queued" {
			startedAt := now
			job.Status = "running"
			job.StartedAt = &startedAt
			pending = append(pending, *job)
		}
	}
	s.devicesMu.Unlock()

	defer func() {
		s.devicesMu.Lock()
		delete(s.deviceJobStreams[deviceID], ch)
		s.devicesMu.Unlock()
		close(ch)
	}()

	for _, job := range pending {
		if !writeTypedSSE(w, flusher, streamEvent{Type: "job", Payload: mustJSON(deviceJobStreamEvent{Type: "job", Job: job})}) {
			return
		}
	}

	keepAlive := time.NewTicker(25 * time.Second)
	defer keepAlive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-keepAlive.C:
			if _, err := io.WriteString(w, ": keep-alive\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case event := <-ch:
			s.devicesMu.Lock()
			if job := s.deviceJobs[event.Job.ID]; job != nil && job.Status == "queued" {
				startedAt := time.Now().UTC()
				job.Status = "running"
				job.StartedAt = &startedAt
				event.Job = *job
			}
			s.devicesMu.Unlock()
			if !writeTypedSSE(w, flusher, streamEvent{Type: "job", Payload: mustJSON(event)}) {
				return
			}
		}
	}
}

func (s *server) handleDeviceJobSubroutes(w http.ResponseWriter, r *http.Request) {
	jobID := strings.Trim(strings.TrimPrefix(r.URL.Path, "/device-jobs/"), "/")
	if jobID == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	if strings.HasSuffix(jobID, "/result") {
		jobID = strings.TrimSuffix(jobID, "/result")
	}
	if strings.HasSuffix(r.URL.Path, "/result") {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleDeviceJobResult(w, r, jobID)
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	s.devicesMu.Lock()
	job := s.deviceJobs[jobID]
	s.devicesMu.Unlock()
	if job == nil {
		writeError(w, http.StatusNotFound, "unknown job")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (s *server) handleDeviceJobResult(w http.ResponseWriter, r *http.Request, jobID string) {
	var req deviceJobResultRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	now := time.Now().UTC()
	s.devicesMu.Lock()
	job := s.deviceJobs[jobID]
	if job == nil {
		s.devicesMu.Unlock()
		writeError(w, http.StatusNotFound, "unknown job")
		return
	}
	job.Result = req.Result
	job.Error = strings.TrimSpace(req.Error)
	job.Logs = append([]string(nil), req.Logs...)
	job.FinishedAt = &now
	if req.OK {
		job.Status = "succeeded"
	} else {
		job.Status = "failed"
		if job.Error == "" {
			job.Error = "device job failed"
		}
	}
	if device, ok := s.devices[job.DeviceID]; ok {
		device.LastSeenAt = now
		s.devices[job.DeviceID] = device
	}
	updated := *job
	s.devicesMu.Unlock()
	writeJSON(w, http.StatusOK, updated)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"error": message})
}

func getenvDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func expandHome(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, strings.TrimPrefix(path, "~/"))
	}
	return path
}

func sanitizeUploadName(name string) string {
	base := filepath.Base(strings.TrimSpace(name))
	if base == "." || base == string(filepath.Separator) || base == "" {
		base = "attachment"
	}
	base = strings.ReplaceAll(base, string(filepath.Separator), "-")
	return base
}

func sanitizeDownloadFilename(name string) string {
	name = sanitizeUploadName(name)
	return strings.NewReplacer("\\", "-", "\"", "'", "\r", " ", "\n", " ").Replace(name)
}

func contentTypeForPath(path string) string {
	if contentType := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); strings.TrimSpace(contentType) != "" {
		return contentType
	}
	return "application/octet-stream"
}

func uniqueUploadName(name string) string {
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	if base == "" {
		base = "attachment"
	}
	return base + "-" + strconv.FormatInt(time.Now().UnixNano(), 10) + ext
}

func xmlEscape(value string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		"\"", "&quot;",
	).Replace(value)
}

// --- Live catalog SSE stream ---

// catalogBroker fans out typed events to all connected SSE clients. The
// initial event is always a `snapshot` carrying the full catalog; subsequent
// events are small typed deltas (session_updated, session_added, ...
// runtime_changed) so the client does not have to reparse the whole
// catalog on every change.
//
// Sends are non-blocking: a slow client that cannot keep up simply misses
// intermediate events and receives the most recent snapshot on reconnect.
type catalogBroker struct {
	mu          sync.RWMutex
	broadcastMu sync.Mutex
	subscribers map[chan streamEvent]struct{}
}

type streamEvent struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

func newCatalogBroker() *catalogBroker {
	return &catalogBroker{subscribers: map[chan streamEvent]struct{}{}}
}

func (b *catalogBroker) subscribe() chan streamEvent {
	ch := make(chan streamEvent, 16)
	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *catalogBroker) unsubscribe(ch chan streamEvent) {
	b.mu.Lock()
	if _, ok := b.subscribers[ch]; ok {
		delete(b.subscribers, ch)
		close(ch)
	}
	b.mu.Unlock()
}

func (b *catalogBroker) broadcast(event streamEvent) {
	b.broadcastMu.Lock()
	defer b.broadcastMu.Unlock()
	b.mu.RLock()
	defer b.mu.RUnlock()
	for ch := range b.subscribers {
		select {
		case ch <- event:
		default:
		}
	}
}

func (b *catalogBroker) broadcastSnapshot(snapshot catalogResponse) {
	raw, err := json.Marshal(snapshot)
	if err != nil {
		return
	}
	b.broadcast(streamEvent{Type: "snapshot", Payload: raw})
}

func (b *catalogBroker) publishSessionUpdated(record sessionRecord) {
	raw, err := json.Marshal(record)
	if err != nil {
		return
	}
	b.broadcast(streamEvent{Type: "session_updated", Payload: raw})
}

func (b *catalogBroker) publishSessionRemoved(sessionID string) {
	raw, err := json.Marshal(map[string]string{"sessionId": sessionID})
	if err != nil {
		return
	}
	b.broadcast(streamEvent{Type: "session_removed", Payload: raw})
}

func (b *catalogBroker) publishRuntimeChanged(payload map[string]any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	b.broadcast(streamEvent{Type: "runtime_changed", Payload: raw})
}

func (b *catalogBroker) subscriberCount() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subscribers)
}

// handleCatalogChange diffs the fresh catalog against the previous in-memory
// snapshot and emits small per-session deltas (`session_updated`,
// `session_removed`). A full `snapshot` is only sent when project topology
// changes or when the catalog was not initialized yet.
func (s *server) handleCatalogChange() {
	s.catalogChangeMu.Lock()
	defer s.catalogChangeMu.Unlock()

	previousSessions, previousProjects, hadCatalog := func() (map[string]sessionRecord, []projectRecord, bool) {
		s.mu.RLock()
		defer s.mu.RUnlock()
		out := make(map[string]sessionRecord, len(s.sessionsByID))
		for id, record := range s.sessionsByID {
			out[id] = record
		}
		projects := append([]projectRecord(nil), s.snapshot.Projects...)
		return out, projects, !s.lastRefresh.IsZero()
	}()
	if err := s.refreshCatalog(true); err != nil {
		log.Printf("catalog refresh failed: %v", err)
		return
	}
	newSessions, snapshot := func() (map[string]sessionRecord, catalogResponse) {
		s.mu.RLock()
		defer s.mu.RUnlock()
		out := make(map[string]sessionRecord, len(s.sessionsByID))
		for id, record := range s.sessionsByID {
			out[id] = record
		}
		return out, s.snapshot
	}()
	if !hadCatalog || !projectsEqual(previousProjects, snapshot.Projects) {
		s.applyGeneratingState(&snapshot)
		s.broker.broadcastSnapshot(snapshot)
		return
	}
	for _, record := range snapshot.Sessions {
		previous, ok := previousSessions[record.ID]
		generating := s.isGeneratingLocked(record.ID)
		record.IsGenerating = generating
		if !ok || previous != record {
			s.broker.publishSessionUpdated(record)
		}
	}
	removedIDs := make([]string, 0)
	for id := range previousSessions {
		if _, ok := newSessions[id]; !ok {
			removedIDs = append(removedIDs, id)
		}
	}
	sort.Strings(removedIDs)
	for _, id := range removedIDs {
		s.broker.publishSessionRemoved(id)
	}
}

func timePtrEqual(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.Equal(*b)
}

func projectsEqual(a, b []projectRecord) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].ID != b[i].ID ||
			a[i].Title != b[i].Title ||
			a[i].WorkingDirectory != b[i].WorkingDirectory ||
			a[i].SessionDirectory != b[i].SessionDirectory ||
			a[i].SessionCount != b[i].SessionCount ||
			!timePtrEqual(a[i].LastActivity, b[i].LastActivity) {
			return false
		}
	}
	return true
}

// watchCatalog runs in its own goroutine. It watches the agent sessions
// directory recursively via fsnotify and triggers a debounced refresh +
// broadcast on any change. New subdirectories are added to the watch list
// on the fly so newly created project folders are picked up.
func (s *server) watchCatalog() {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("fsnotify: live catalog updates disabled: %v", err)
		return
	}
	defer watcher.Close()

	sessionsRoot := filepath.Join(s.agentDir, "sessions")
	if err := s.addWatchRecursive(watcher, sessionsRoot); err != nil {
		log.Printf("fsnotify: live catalog watcher incomplete for %s: %v", sessionsRoot, err)
	}

	const debounce = 300 * time.Millisecond
	var debounceTimer *time.Timer

	schedule := func() {
		if debounceTimer != nil {
			debounceTimer.Stop()
		}
		debounceTimer = time.AfterFunc(debounce, s.handleCatalogChange)
	}

	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			if event.Op&fsnotify.Create != 0 {
				if info, statErr := os.Stat(event.Name); statErr == nil && info.IsDir() {
					if addErr := watcher.Add(event.Name); addErr != nil {
						log.Printf("fsnotify: watch %s: %v", event.Name, addErr)
					}
				}
			}
			schedule()
		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			log.Printf("fsnotify error: %v", err)
		}
	}
}

func (s *server) addWatchRecursive(watcher *fsnotify.Watcher, root string) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			return watcher.Add(path)
		}
		return nil
	})
}

// handleSessionsStream serves GET /sessions/stream as a Server-Sent Events
// endpoint. It sends a full catalog snapshot on connect, then keeps the
// connection open sending fresh snapshots whenever the catalog changes and a
// short heartbeat comment every 15s to keep proxies and browsers happy.
func (s *server) handleSessionsStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// Subscribe before refreshing so any change that happens during the
	// initial refresh is delivered via the channel rather than being missed.
	ch := s.broker.subscribe()
	defer s.broker.unsubscribe(ch)

	if err := s.refreshCatalogIfNeeded(); err != nil {
		writeSSEError(w, flusher, err.Error())
		return
	}
	s.mu.RLock()
	initial := s.snapshot
	s.mu.RUnlock()
	if !writeTypedSSE(w, flusher, streamEvent{Type: "snapshot", Payload: mustJSON(initial)}) {
		return
	}

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			if _, err := io.WriteString(w, ": ping\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case event, ok := <-ch:
			if !ok {
				return
			}
			if !writeTypedSSE(w, flusher, event) {
				return
			}
		}
	}
}

func mustJSON(value any) json.RawMessage {
	data, err := json.Marshal(value)
	if err != nil {
		log.Printf("stream event encode failed: %v", err)
		return nil
	}
	return data
}

func writeTypedSSE(w http.ResponseWriter, flusher http.Flusher, event streamEvent) bool {
	if len(event.Payload) == 0 {
		if _, err := io.WriteString(w, "event: "+event.Type+"\n\n"); err != nil {
			return false
		}
	} else {
		if _, err := io.WriteString(w, "event: "+event.Type+"\ndata: "); err != nil {
			return false
		}
		if _, err := w.Write(event.Payload); err != nil {
			return false
		}
		if _, err := io.WriteString(w, "\n\n"); err != nil {
			return false
		}
	}
	flusher.Flush()
	return true
}

// writeSSE serialises payload as a single SSE event. Returns false if the
// underlying writer is broken (client disconnect), so the caller can abort.
func writeSSE(w http.ResponseWriter, flusher http.Flusher, event string, payload any) bool {
	data, err := json.Marshal(payload)
	if err != nil {
		return false
	}
	if _, err := io.WriteString(w, "event: "+event+"\ndata: "); err != nil {
		return false
	}
	if _, err := w.Write(data); err != nil {
		return false
	}
	if _, err := io.WriteString(w, "\n\n"); err != nil {
		return false
	}
	flusher.Flush()
	return true
}

func writeSSEError(w http.ResponseWriter, flusher http.Flusher, message string) {
	_, _ = io.WriteString(w, "event: error\ndata: ")
	data, _ := json.Marshal(map[string]string{"error": message})
	_, _ = w.Write(data)
	_, _ = io.WriteString(w, "\n\n")
	flusher.Flush()
}
