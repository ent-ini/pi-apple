package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	_ "modernc.org/sqlite"
)

// attachmentStore makes object storage authoritative while preserving a verified
// local POSIX cache for pi tools and RPC image/file handling.
type attachmentStore struct {
	db        *sql.DB
	localRoot string
	backend   string
	bucket    string
	prefix    string
	client    *minio.Client
	retention time.Duration
	gcEvery   time.Duration
	mu        sync.Mutex // serialises materialisation of an individual small cache
}

type attachmentRecord struct {
	ID           string
	ObjectKey    string
	FileName     string
	MimeType     string
	Size         int64
	SHA256       string
	LocalPath    string
	State        string
	RemoteExists bool
	CreatedAt    time.Time
	ExpiresAt    time.Time
}

var attachmentIDPattern = regexp.MustCompile(`^att_[a-f0-9]{32}$`)

func newAttachmentStore(agentDir string) (*attachmentStore, error) {
	backend := strings.ToLower(strings.TrimSpace(getenvDefault("PI_APPD_UPLOAD_BACKEND", "local")))
	if backend == "s3" { // s3 retains the local materialized cache, like dual.
		backend = "dual"
	}
	if backend != "local" && backend != "dual" {
		return nil, fmt.Errorf("PI_APPD_UPLOAD_BACKEND must be local, dual, or s3")
	}
	localRoot := expandHome(getenvDefault("PI_APPD_ATTACHMENT_LOCAL_DIR", filepath.Join(agentDir, "uploads")))
	if err := os.MkdirAll(localRoot, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(localRoot, 0o700); err != nil {
		return nil, err
	}
	dbPath := expandHome(getenvDefault("PI_APPD_ATTACHMENTS_DB", filepath.Join(agentDir, "uploads.db")))
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", dbPath+"?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	// SQLite creates the DB lazily, so force the connection before tightening
	// DB/WAL/SHM permissions below.
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	for _, path := range []string{dbPath, dbPath + "-wal", dbPath + "-shm"} {
		if err := os.Chmod(path, 0o600); err != nil && !errors.Is(err, os.ErrNotExist) {
			db.Close()
			return nil, err
		}
	}
	store := &attachmentStore{
		db:        db,
		localRoot: localRoot,
		backend:   backend,
		retention: durationEnv("PI_APPD_UPLOAD_BOUND_RETENTION", 90*24*time.Hour),
		gcEvery:   durationEnv("PI_APPD_ATTACHMENT_GC_INTERVAL", time.Hour),
		prefix:    strings.Trim(strings.TrimSpace(getenvDefault("PI_APPD_S3_PREFIX", "v1/attachments")), "/"),
	}
	if store.gcEvery <= 0 || store.retention <= 0 {
		db.Close()
		return nil, errors.New("attachment retention and GC interval must be positive")
	}
	if err := store.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	if backend == "dual" {
		endpoint := strings.TrimSpace(os.Getenv("PI_APPD_S3_ENDPOINT"))
		store.bucket = strings.TrimSpace(os.Getenv("PI_APPD_S3_BUCKET"))
		accessKey := strings.TrimSpace(os.Getenv("PI_APPD_S3_ACCESS_KEY"))
		secretKey := strings.TrimSpace(os.Getenv("PI_APPD_S3_SECRET_KEY"))
		if endpoint == "" || store.bucket == "" || accessKey == "" || secretKey == "" {
			db.Close()
			return nil, errors.New("dual attachment storage requires PI_APPD_S3_ENDPOINT, PI_APPD_S3_BUCKET, PI_APPD_S3_ACCESS_KEY, and PI_APPD_S3_SECRET_KEY")
		}
		secure := strings.EqualFold(getenvDefault("PI_APPD_S3_SECURE", "true"), "true")
		endpoint = strings.TrimPrefix(strings.TrimPrefix(endpoint, "https://"), "http://")
		endpoint = strings.TrimSuffix(endpoint, "/")
		client, clientErr := minio.New(endpoint, &minio.Options{
			Creds:  credentials.NewStaticV4(accessKey, secretKey, strings.TrimSpace(os.Getenv("PI_APPD_S3_SESSION_TOKEN"))),
			Secure: secure,
		})
		if clientErr != nil {
			db.Close()
			return nil, clientErr
		}
		store.client = client
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		exists, bucketErr := client.BucketExists(ctx, store.bucket)
		if bucketErr != nil {
			db.Close()
			return nil, fmt.Errorf("MinIO bucket check: %w", bucketErr)
		}
		if !exists {
			if err := client.MakeBucket(ctx, store.bucket, minio.MakeBucketOptions{Region: getenvDefault("PI_APPD_S3_REGION", "us-east-1")}); err != nil {
				db.Close()
				return nil, fmt.Errorf("MinIO bucket create: %w", err)
			}
		}
	}
	return store, nil
}

func (s *attachmentStore) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS attachments (
 id TEXT PRIMARY KEY,
 bucket TEXT NOT NULL DEFAULT '',
 object_key TEXT NOT NULL UNIQUE,
 original_file_name TEXT NOT NULL,
 safe_file_name TEXT NOT NULL,
 mime_type TEXT NOT NULL DEFAULT '',
 size_bytes INTEGER NOT NULL,
 sha256 TEXT NOT NULL,
 local_path TEXT NOT NULL UNIQUE,
 state TEXT NOT NULL,
 remote_present INTEGER NOT NULL DEFAULT 0,
 created_at TEXT NOT NULL,
 uploaded_at TEXT,
 last_accessed_at TEXT,
 expires_at TEXT NOT NULL,
 deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS attachments_expiry ON attachments(state, expires_at);
CREATE TABLE IF NOT EXISTS attachment_refs (
 id TEXT PRIMARY KEY,
 attachment_id TEXT NOT NULL REFERENCES attachments(id),
 session_id TEXT,
 request_id TEXT,
 attached_at TEXT NOT NULL,
 retain_until TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS attachment_refs_attachment ON attachment_refs(attachment_id);
CREATE TABLE IF NOT EXISTS outbound_attachment_refs (
 session_id TEXT NOT NULL,
 message_id TEXT NOT NULL,
 source_path TEXT NOT NULL,
 attachment_id TEXT NOT NULL REFERENCES attachments(id),
 created_at TEXT NOT NULL,
 PRIMARY KEY(session_id, message_id, source_path)
);
CREATE INDEX IF NOT EXISTS outbound_attachment_refs_attachment ON outbound_attachment_refs(attachment_id);
`)
	return err
}

func (s *attachmentStore) Close() error { return s.db.Close() }

func (s *attachmentStore) Upload(ctx context.Context, source io.Reader, originalName, mimeType string) (attachmentRecord, error) {
	id, err := newAttachmentID()
	if err != nil {
		return attachmentRecord{}, err
	}
	now := time.Now().UTC()
	safeName := sanitizeUploadName(originalName)
	localPath := filepath.Join(s.localRoot, now.Format("2006"), now.Format("01"), id, safeName)
	objectKey := strings.Trim(s.prefix+"/"+now.Format("2006/01/02")+"/"+id+"/blob", "/")
	record := attachmentRecord{ID: id, ObjectKey: objectKey, FileName: safeName, MimeType: strings.TrimSpace(mimeType), LocalPath: localPath, State: "pending", CreatedAt: now, ExpiresAt: now.Add(s.retention)}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return attachmentRecord{}, err
	}
	temp, err := os.CreateTemp(filepath.Dir(localPath), ".upload-*")
	if err != nil {
		return attachmentRecord{}, err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return attachmentRecord{}, err
	}
	hash := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(temp, hash), io.LimitReader(source, maxUploadFileBytes+1))
	if closeErr := temp.Close(); copyErr != nil {
		return attachmentRecord{}, copyErr
	} else if closeErr != nil {
		return attachmentRecord{}, closeErr
	}
	if n > maxUploadFileBytes {
		return attachmentRecord{}, errAttachmentTooLarge
	}
	record.Size, record.SHA256 = n, hex.EncodeToString(hash.Sum(nil))
	record.MimeType = normalizedUploadMIME(tempPath, safeName, record.MimeType)
	// Reject an image at the upload stage, while both clients can still restore
	// their draft/chips. Accepting it into MinIO only to reject /input later
	// creates an orphan and an ambiguous submitted-send UX.
	if strings.HasPrefix(strings.ToLower(record.MimeType), "image/") && record.Size > maxImageAttachmentBytes {
		return attachmentRecord{}, errAttachmentTooLarge
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO attachments (id,bucket,object_key,original_file_name,safe_file_name,mime_type,size_bytes,sha256,local_path,state,remote_present,created_at,expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`, record.ID, s.bucket, record.ObjectKey, safeName, safeName, record.MimeType, record.Size, record.SHA256, record.LocalPath, "pending", 0, timestamp(record.CreatedAt), timestamp(record.ExpiresAt)); err != nil {
		return attachmentRecord{}, err
	}
	if err := os.Rename(tempPath, localPath); err != nil {
		s.deleteRow(record.ID)
		return attachmentRecord{}, err
	}
	if s.backend == "dual" {
		if err := s.putRemote(ctx, record); err != nil {
			// There is no retry/reconciliation worker for pending rows. Roll the
			// failed attempt back so a client retry cannot leave an inaccessible
			// local file and immortal pending DB row behind.
			s.rollbackUpload(context.Background(), record)
			return attachmentRecord{}, fmt.Errorf("store attachment in MinIO: %w", err)
		}
		record.RemoteExists = true
	}
	record.State = "available"
	if _, err := s.db.ExecContext(ctx, `UPDATE attachments SET state='available', remote_present=?, uploaded_at=?, last_accessed_at=? WHERE id=?`, boolInt(record.RemoteExists), timestamp(now), timestamp(now), record.ID); err != nil {
		s.rollbackUpload(context.Background(), record)
		return attachmentRecord{}, err
	}
	return record, nil
}

func normalizedUploadMIME(path, fileName, declared string) string {
	declared = strings.TrimSpace(strings.Split(declared, ";")[0])
	if strings.ContainsAny(declared, "\r\n") {
		declared = ""
	}
	file, err := os.Open(path)
	if err != nil {
		return firstNonBlank(declared, contentTypeForPath(fileName), "application/octet-stream")
	}
	defer file.Close()
	header := make([]byte, 512)
	n, _ := io.ReadFull(file, header)
	header = header[:n]
	detected := http.DetectContentType(header)
	brand := ""
	if len(header) > 8 {
		brand = string(header[8:min(32, len(header))])
	}
	isHEIC := len(header) >= 12 && string(header[4:8]) == "ftyp" && (strings.Contains(brand, "heic") || strings.Contains(brand, "heif") || strings.Contains(brand, "mif1"))
	if isHEIC {
		if strings.HasSuffix(strings.ToLower(fileName), ".heif") {
			return "image/heif"
		}
		return "image/heic"
	}
	// Never let an untrusted declared image type route arbitrary bytes into a
	// vision provider or ImageMagick. Other declarations remain useful for ZIP
	// containers such as docx, where generic byte sniffing loses the real type.
	if strings.HasPrefix(strings.ToLower(declared), "image/") && !strings.HasPrefix(detected, "image/") {
		return detected
	}
	return firstNonBlank(declared, detected, contentTypeForPath(fileName), "application/octet-stream")
}

func (s *attachmentStore) putRemote(ctx context.Context, record attachmentRecord) error {
	file, err := os.Open(record.LocalPath)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = s.client.PutObject(ctx, s.bucket, record.ObjectKey, file, record.Size, minio.PutObjectOptions{ContentType: firstNonBlank(record.MimeType, "application/octet-stream")})
	return err
}

func (s *attachmentStore) Get(ctx context.Context, id string) (attachmentRecord, error) {
	if !attachmentIDPattern.MatchString(id) {
		return attachmentRecord{}, errAttachmentNotFound
	}
	row := s.db.QueryRowContext(ctx, `SELECT id,object_key,safe_file_name,mime_type,size_bytes,sha256,local_path,state,remote_present,created_at,expires_at FROM attachments WHERE id=? AND state='available'`, id)
	var record attachmentRecord
	var remote int
	var created, expires string
	if err := row.Scan(&record.ID, &record.ObjectKey, &record.FileName, &record.MimeType, &record.Size, &record.SHA256, &record.LocalPath, &record.State, &remote, &created, &expires); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return attachmentRecord{}, errAttachmentNotFound
		}
		return attachmentRecord{}, err
	}
	record.RemoteExists = remote != 0
	record.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	record.ExpiresAt, _ = time.Parse(time.RFC3339Nano, expires)
	return record, nil
}

func (s *attachmentStore) EnsureLocal(ctx context.Context, id string) (attachmentRecord, error) {
	// Serialize with GC and materialisation. Without this lock GC could mark the
	// row pending and unlink the cache between Get/touch/open in a download or
	// active agent turn.
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.Get(ctx, id)
	if err != nil {
		return attachmentRecord{}, err
	}
	if s.validLocal(record) {
		s.touch(ctx, id)
		return record, nil
	}
	if !record.RemoteExists || s.client == nil {
		return attachmentRecord{}, errAttachmentNotFound
	}
	if err := os.MkdirAll(filepath.Dir(record.LocalPath), 0o700); err != nil {
		return attachmentRecord{}, err
	}
	object, err := s.client.GetObject(ctx, s.bucket, record.ObjectKey, minio.GetObjectOptions{})
	if err != nil {
		return attachmentRecord{}, err
	}
	defer object.Close()
	temp, err := os.CreateTemp(filepath.Dir(record.LocalPath), ".materialize-*")
	if err != nil {
		return attachmentRecord{}, err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	_ = temp.Chmod(0o600)
	hash := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(temp, hash), io.LimitReader(object, maxUploadFileBytes+1))
	closeErr := temp.Close()
	if copyErr != nil {
		return attachmentRecord{}, copyErr
	}
	if closeErr != nil {
		return attachmentRecord{}, closeErr
	}
	if n != record.Size || n > maxUploadFileBytes || hex.EncodeToString(hash.Sum(nil)) != record.SHA256 {
		return attachmentRecord{}, errors.New("materialized attachment checksum mismatch")
	}
	if err := os.Rename(tempPath, record.LocalPath); err != nil {
		return attachmentRecord{}, err
	}
	s.touch(ctx, id)
	return record, nil
}

// ImportOutbound stores an assistant-authored local file exactly once for a
// persisted session message. The binding keeps old chat history downloadable
// even after the original workspace file changes or disappears.
func (s *attachmentStore) ImportOutbound(ctx context.Context, sessionID, messageID, sourcePath string) (attachmentRecord, error) {
	sessionID = strings.TrimSpace(sessionID)
	messageID = strings.TrimSpace(messageID)
	sourcePath = filepath.Clean(strings.TrimSpace(sourcePath))
	if sessionID == "" || messageID == "" || sourcePath == "." {
		return attachmentRecord{}, errAttachmentNotFound
	}

	// Event pagination and SSE can request the same line concurrently. Keep the
	// lookup/upload transaction serialized so a single @path creates one object.
	s.mu.Lock()
	defer s.mu.Unlock()

	var attachmentID string
	err := s.db.QueryRowContext(ctx, `SELECT attachment_id FROM outbound_attachment_refs WHERE session_id=? AND message_id=? AND source_path=?`, sessionID, messageID, sourcePath).Scan(&attachmentID)
	if err == nil {
		return s.Get(ctx, attachmentID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return attachmentRecord{}, err
	}

	file, err := os.Open(sourcePath)
	if err != nil {
		return attachmentRecord{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return attachmentRecord{}, err
	}
	if !info.Mode().IsRegular() {
		return attachmentRecord{}, errors.New("outbound attachment is not a regular file")
	}
	if info.Size() > maxUploadFileBytes {
		return attachmentRecord{}, errAttachmentTooLarge
	}

	record, err := s.Upload(ctx, file, filepath.Base(sourcePath), contentTypeForPath(sourcePath))
	if err != nil {
		return attachmentRecord{}, err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO outbound_attachment_refs(session_id,message_id,source_path,attachment_id,created_at) VALUES (?,?,?,?,?)`, sessionID, messageID, sourcePath, record.ID, timestamp(time.Now().UTC())); err != nil {
		return attachmentRecord{}, err
	}
	s.Bind(ctx, []attachmentReference{{ID: record.ID}}, sessionID)
	return record, nil
}

func (s *attachmentStore) validLocal(record attachmentRecord) bool {
	info, err := os.Lstat(record.LocalPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() != record.Size || !pathWithinRoot(record.LocalPath, s.localRoot) {
		return false
	}
	file, err := os.Open(record.LocalPath)
	if err != nil {
		return false
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return false
	}
	return hex.EncodeToString(hash.Sum(nil)) == record.SHA256
}

func (s *attachmentStore) touch(ctx context.Context, id string) {
	now := time.Now().UTC()
	until := now.Add(s.retention)
	// Access renews availability. A file opened from old chat history should not
	// be deleted minutes later merely because its original upload TTL elapsed.
	_, _ = s.db.ExecContext(ctx, `UPDATE attachments SET last_accessed_at=?, expires_at=? WHERE id=? AND state='available'`, timestamp(now), timestamp(until), id)
}

func (s *attachmentStore) Bind(ctx context.Context, attachments []attachmentReference, sessionID string) {
	until := time.Now().UTC().Add(s.retention)
	for _, attachment := range attachments {
		if !attachmentIDPattern.MatchString(attachment.ID) {
			continue
		}
		_, _ = s.db.ExecContext(ctx, `INSERT INTO attachment_refs(id,attachment_id,session_id,attached_at,retain_until) VALUES (?,?,?,?,?)`, randomHex(16), attachment.ID, sessionID, timestamp(time.Now().UTC()), timestamp(until))
		_, _ = s.db.ExecContext(ctx, `UPDATE attachments SET expires_at=? WHERE id=? AND expires_at < ?`, timestamp(until), attachment.ID, timestamp(until))
	}
}

func (s *attachmentStore) runGC() {
	ticker := time.NewTicker(s.gcEvery)
	defer ticker.Stop()
	for range ticker.C {
		if err := s.collectExpired(context.Background()); err != nil {
			fmt.Printf("attachment GC: %v\n", err)
		}
	}
}

func (s *attachmentStore) collectExpired(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.QueryContext(ctx, `SELECT id,object_key,local_path,remote_present FROM attachments WHERE state='available' AND expires_at <= ? LIMIT 100`, timestamp(time.Now().UTC()))
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, key, path string
		var remote int
		if err := rows.Scan(&id, &key, &path, &remote); err != nil {
			return err
		}
		result, err := s.db.ExecContext(ctx, `UPDATE attachments SET state='gc_pending' WHERE id=? AND state='available'`, id)
		if err != nil {
			return err
		}
		changed, _ := result.RowsAffected()
		if changed == 0 {
			continue
		}
		if remote != 0 && s.client != nil {
			if err := s.client.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{}); err != nil {
				_, _ = s.db.ExecContext(ctx, `UPDATE attachments SET state='available' WHERE id=?`, id)
				continue
			}
		}
		_ = os.Remove(path)
		_ = os.Remove(filepath.Dir(path))
		_, _ = s.db.ExecContext(ctx, `UPDATE attachments SET state='deleted', deleted_at=? WHERE id=?`, timestamp(time.Now().UTC()), id)
	}
	return rows.Err()
}

func (s *attachmentStore) rollbackUpload(ctx context.Context, record attachmentRecord) {
	if s.client != nil {
		// PutObject can finish server-side while its response is lost. Removing an
		// opaque unique key is safe even when the object was never created.
		_ = s.client.RemoveObject(ctx, s.bucket, record.ObjectKey, minio.RemoveObjectOptions{})
	}
	_ = os.Remove(record.LocalPath)
	_ = os.Remove(filepath.Dir(record.LocalPath))
	s.deleteRow(record.ID)
}

func (s *attachmentStore) deleteRow(id string) {
	_, _ = s.db.Exec(`DELETE FROM attachments WHERE id=?`, id)
}
func newAttachmentID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "att_" + hex.EncodeToString(b), nil
}
func randomHex(bytes int) string {
	b := make([]byte, bytes)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("fallback-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}
func timestamp(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
func durationEnv(name string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback
	}
	value, err := time.ParseDuration(raw)
	if err != nil {
		return fallback
	}
	return value
}

var errAttachmentTooLarge = errors.New("attachment is too large")
var errAttachmentNotFound = errors.New("attachment not found")
