package upload

import (
	"context"
	"encoding/json"
	"os"
	"time"

	"github.com/fengtianyu/memorystore/server/internal/config"
	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/internal/storage"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/fengtianyu/memorystore/server/pkg/hashutil"
	"github.com/fengtianyu/memorystore/server/pkg/ids"
)

type Service struct {
	Uploads  *repo.UploadRepo
	Media    *repo.MediaRepo
	Jobs     *repo.JobRepo
	Storage  *storage.Engine
	UploadCfg config.UploadConfig
}

type InitInput struct {
	ContentHash string `json:"content_hash"`
	SizeBytes   int64  `json:"size_bytes"`
	MimeType    string `json:"mime_type"`
	MediaType   string `json:"media_type"`
	TakenAt     string `json:"taken_at"`
	Width       *int64 `json:"width"`
	Height      *int64 `json:"height"`
	DurationMs  *int64 `json:"duration_ms"`
	Filename    string `json:"filename"`
	DeviceID    string `json:"device_id"`
}

type InitResult struct {
	UploadID      string `json:"upload_id,omitempty"`
	ResumeFrom    int64  `json:"resume_from,omitempty"`
	AlreadyExists bool   `json:"already_exists"`
	MediaID       string `json:"media_id,omitempty"`
	ContentHash   string `json:"content_hash,omitempty"`
}

type CheckResult struct {
	Existing []ExistingItem `json:"existing"`
	Missing  []string       `json:"missing"`
}

type ExistingItem struct {
	Hash      string `json:"hash"`
	MediaID   string `json:"media_id"`
	SizeBytes int64  `json:"size_bytes"`
}

func (s *Service) Check(ctx context.Context, userID string, hashes []string) (*CheckResult, error) {
	if len(hashes) > 500 {
		return nil, apperr.New(apperr.BadRequest, "too many hashes")
	}
	found, err := s.Media.ExistsHashes(ctx, userID, hashes)
	if err != nil {
		return nil, err
	}
	res := &CheckResult{}
	seen := map[string]bool{}
	for _, h := range hashes {
		if m, ok := found[h]; ok {
			res.Existing = append(res.Existing, ExistingItem{Hash: h, MediaID: m.ID, SizeBytes: m.SizeBytes})
			seen[h] = true
		}
	}
	for _, h := range hashes {
		if !seen[h] {
			res.Missing = append(res.Missing, h)
		}
	}
	return res, nil
}

func (s *Service) Init(ctx context.Context, userID string, in InitInput) (*InitResult, error) {
	if in.ContentHash == "" || in.SizeBytes <= 0 {
		return nil, apperr.New(apperr.BadRequest, "hash and size required")
	}
	if in.SizeBytes > s.UploadCfg.MaxBytes {
		return nil, apperr.New(apperr.UploadTooLarge, "file too large")
	}
	if in.MediaType == "" {
		in.MediaType = "photo"
	}
	existing, err := s.Media.ByUserHash(ctx, userID, in.ContentHash)
	if err != nil {
		return nil, err
	}
	if existing != nil {
		return &InitResult{AlreadyExists: true, MediaID: existing.ID, ContentHash: existing.ContentHash}, nil
	}
	if open, err := s.Uploads.FindOpenByHash(ctx, userID, in.ContentHash); err != nil {
		return nil, err
	} else if open != nil && time.Now().UTC().Before(open.ExpiresAt) {
		return &InitResult{UploadID: open.ID, ResumeFrom: open.ReceivedBytes}, nil
	}

	meta, _ := json.Marshal(in)
	uploadID := ids.New()
	dir, err := s.Storage.EnsureUploadTmp(userID, uploadID)
	if err != nil {
		return nil, err
	}
	dataPath := s.Storage.UploadDataPath(userID, uploadID)
	f, err := os.OpenFile(dataPath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, err
	}
	_ = f.Close()

	sess := &repo.UploadSession{
		ID:          uploadID,
		UserID:      userID,
		DeviceID:    in.DeviceID,
		ContentHash: in.ContentHash,
		SizeBytes:   in.SizeBytes,
		TmpDir:      dir,
		Status:      "open",
		MetaJSON:    string(meta),
		ExpiresAt:   time.Now().UTC().Add(s.UploadCfg.SessionTTL()),
	}
	if err := s.Uploads.Create(ctx, sess); err != nil {
		return nil, err
	}
	return &InitResult{UploadID: uploadID, ResumeFrom: 0}, nil
}

func (s *Service) Status(ctx context.Context, userID, uploadID string) (*repo.UploadSession, error) {
	sess, err := s.Uploads.ByID(ctx, uploadID)
	if err != nil {
		return nil, err
	}
	if sess == nil || sess.UserID != userID {
		return nil, apperr.New(apperr.NotFound, "upload not found")
	}
	return sess, nil
}

func (s *Service) WriteChunk(ctx context.Context, userID, uploadID string, offset int64, data []byte) (int64, error) {
	sess, err := s.Status(ctx, userID, uploadID)
	if err != nil {
		return 0, err
	}
	if sess.Status != "open" {
		return 0, apperr.New(apperr.BadRequest, "upload not open")
	}
	if time.Now().UTC().After(sess.ExpiresAt) {
		return 0, apperr.New(apperr.BadRequest, "upload expired")
	}
	if offset != sess.ReceivedBytes {
		return 0, apperr.New(apperr.BadRequest, "unexpected chunk offset")
	}
	if offset+int64(len(data)) > sess.SizeBytes {
		return 0, apperr.New(apperr.BadRequest, "chunk exceeds declared size")
	}
	path := s.Storage.UploadDataPath(userID, uploadID)
	f, err := os.OpenFile(path, os.O_RDWR, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if _, err := f.WriteAt(data, offset); err != nil {
		return 0, apperr.Wrap(apperr.InsufficientStorage, "write failed", err)
	}
	received := offset + int64(len(data))
	if err := s.Uploads.UpdateReceived(ctx, uploadID, received); err != nil {
		return 0, err
	}
	return received, nil
}

type CompleteResult struct {
	MediaID     string `json:"media_id"`
	ContentHash string `json:"content_hash"`
	SizeBytes   int64  `json:"size_bytes"`
	Status      string `json:"status"`
}

func (s *Service) Complete(ctx context.Context, userID, uploadID string) (*CompleteResult, error) {
	sess, err := s.Status(ctx, userID, uploadID)
	if err != nil {
		return nil, err
	}
	if sess.Status != "open" {
		if sess.Status == "completed" && sess.MediaID != "" {
			return &CompleteResult{MediaID: sess.MediaID, ContentHash: sess.ContentHash, SizeBytes: sess.SizeBytes, Status: "stored"}, nil
		}
		return nil, apperr.New(apperr.BadRequest, "upload not open")
	}
	if sess.ReceivedBytes != sess.SizeBytes {
		return nil, apperr.New(apperr.UploadIncomplete, "bytes incomplete")
	}
	path := s.Storage.UploadDataPath(userID, uploadID)
	gotHash, err := hashutil.SHA256File(path)
	if err != nil {
		return nil, err
	}
	if gotHash != sess.ContentHash {
		_ = s.Storage.RemoveUploadTmp(userID, uploadID)
		_ = s.Uploads.Abort(ctx, uploadID, "aborted")
		return nil, apperr.New(apperr.UploadHashMismatch, "hash mismatch")
	}

	if existing, err := s.Media.ByUserHash(ctx, userID, sess.ContentHash); err != nil {
		return nil, err
	} else if existing != nil {
		_ = s.Storage.RemoveUploadTmp(userID, uploadID)
		_ = s.Uploads.Complete(ctx, uploadID, existing.ID)
		return &CompleteResult{MediaID: existing.ID, ContentHash: existing.ContentHash, SizeBytes: existing.SizeBytes, Status: "stored"}, nil
	}

	var meta InitInput
	_ = json.Unmarshal([]byte(sess.MetaJSON), &meta)
	takenAt := time.Now().UTC()
	if meta.TakenAt != "" {
		if t, err := time.Parse(time.RFC3339, meta.TakenAt); err == nil {
			takenAt = t.UTC()
		} else if t, err := time.Parse(time.RFC3339Nano, meta.TakenAt); err == nil {
			takenAt = t.UTC()
		}
	}
	mime := meta.MimeType
	if mime == "" {
		mime = "application/octet-stream"
	}
	mediaType := meta.MediaType
	if mediaType == "" {
		mediaType = "photo"
	}
	mediaID := ids.New()
	rel := s.Storage.OriginalRelPath(userID, mediaID, sess.ContentHash, storage.ExtFromMIME(mime), takenAt)
	if err := s.Storage.CommitUpload(userID, uploadID, rel); err != nil {
		return nil, apperr.Wrap(apperr.InsufficientStorage, "commit failed", err)
	}
	m := &repo.Media{
		ID:             mediaID,
		UserID:         userID,
		ContentHash:    sess.ContentHash,
		MimeType:       mime,
		MediaType:      mediaType,
		SizeBytes:      sess.SizeBytes,
		Width:          meta.Width,
		Height:         meta.Height,
		DurationMs:     meta.DurationMs,
		TakenAt:        &takenAt,
		OriginalPath:   rel,
		Status:         "pending_derivatives",
		SourceDeviceID: sess.DeviceID,
	}
	if err := s.Media.Create(ctx, m); err != nil {
		return nil, err
	}
	_ = s.Uploads.Complete(ctx, uploadID, mediaID)
	payload, _ := json.Marshal(map[string]string{"media_id": mediaID, "user_id": userID})
	_ = s.Jobs.Enqueue(ctx, &repo.Job{ID: ids.New(), Type: "generate_derivatives", Payload: string(payload)})
	return &CompleteResult{MediaID: mediaID, ContentHash: sess.ContentHash, SizeBytes: sess.SizeBytes, Status: "stored"}, nil
}

func (s *Service) Abort(ctx context.Context, userID, uploadID string) error {
	sess, err := s.Status(ctx, userID, uploadID)
	if err != nil {
		return err
	}
	_ = s.Storage.RemoveUploadTmp(userID, uploadID)
	return s.Uploads.Abort(ctx, sess.ID, "aborted")
}
