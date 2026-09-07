package repo

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type UploadSession struct {
	ID            string
	UserID        string
	DeviceID      string
	ContentHash   string
	SizeBytes     int64
	ReceivedBytes int64
	TmpDir        string
	Status        string
	MetaJSON      string
	ExpiresAt     time.Time
	MediaID       string
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

type UploadRepo struct{ DB *sql.DB }

func (r *UploadRepo) Create(ctx context.Context, s *UploadSession) error {
	now := nowUTC()
	_, err := r.DB.ExecContext(ctx, `INSERT INTO upload_sessions(id, user_id, device_id, content_hash, size_bytes, received_bytes, tmp_dir, status, meta_json, expires_at, created_at, updated_at)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		s.ID, s.UserID, nullStr(s.DeviceID), s.ContentHash, s.SizeBytes, s.ReceivedBytes, s.TmpDir, s.Status, nullStr(s.MetaJSON),
		s.ExpiresAt.UTC().Format(time.RFC3339Nano), now, now)
	return err
}

func (r *UploadRepo) ByID(ctx context.Context, id string) (*UploadSession, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, COALESCE(device_id,''), content_hash, size_bytes, received_bytes, tmp_dir, status, COALESCE(meta_json,''), expires_at, COALESCE(media_id,''), created_at, updated_at
		FROM upload_sessions WHERE id=?`, id)
	return scanUpload(row)
}

func (r *UploadRepo) FindOpenByHash(ctx context.Context, userID, hash string) (*UploadSession, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, COALESCE(device_id,''), content_hash, size_bytes, received_bytes, tmp_dir, status, COALESCE(meta_json,''), expires_at, COALESCE(media_id,''), created_at, updated_at
		FROM upload_sessions WHERE user_id=? AND content_hash=? AND status='open' ORDER BY created_at DESC LIMIT 1`, userID, hash)
	return scanUpload(row)
}

func (r *UploadRepo) UpdateReceived(ctx context.Context, id string, received int64) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE upload_sessions SET received_bytes=?, updated_at=? WHERE id=?`, received, nowUTC(), id)
	return err
}

func (r *UploadRepo) Complete(ctx context.Context, id, mediaID string) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE upload_sessions SET status='completed', media_id=?, updated_at=? WHERE id=?`, mediaID, nowUTC(), id)
	return err
}

func (r *UploadRepo) Abort(ctx context.Context, id, status string) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE upload_sessions SET status=?, updated_at=? WHERE id=?`, status, nowUTC(), id)
	return err
}

func scanUpload(row *sql.Row) (*UploadSession, error) {
	var s UploadSession
	var exp, created, updated string
	err := row.Scan(&s.ID, &s.UserID, &s.DeviceID, &s.ContentHash, &s.SizeBytes, &s.ReceivedBytes, &s.TmpDir, &s.Status, &s.MetaJSON, &exp, &s.MediaID, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.ExpiresAt, _ = time.Parse(time.RFC3339Nano, exp)
	s.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	s.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
	return &s, nil
}

type Job struct {
	ID          string
	Type        string
	Payload     string
	Status      string
	Attempts    int
	AvailableAt time.Time
	LastError   string
}

type JobRepo struct{ DB *sql.DB }

func (r *JobRepo) Enqueue(ctx context.Context, j *Job) error {
	now := nowUTC()
	avail := j.AvailableAt
	if avail.IsZero() {
		avail = time.Now().UTC()
	}
	_, err := r.DB.ExecContext(ctx, `INSERT INTO jobs(id, type, payload, status, attempts, available_at, created_at, updated_at)
		VALUES(?,?,?,?,?,?,?,?)`, j.ID, j.Type, j.Payload, "pending", 0, avail.Format(time.RFC3339Nano), now, now)
	return err
}

func (r *JobRepo) ClaimNext(ctx context.Context) (*Job, error) {
	tx, err := r.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()
	row := tx.QueryRowContext(ctx, `SELECT id, type, payload, status, attempts, available_at, COALESCE(last_error,'') FROM jobs
		WHERE status='pending' AND available_at <= ? ORDER BY available_at ASC LIMIT 1`, nowUTC())
	var j Job
	var avail string
	if err := row.Scan(&j.ID, &j.Type, &j.Payload, &j.Status, &j.Attempts, &avail, &j.LastError); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	j.AvailableAt, _ = time.Parse(time.RFC3339Nano, avail)
	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET status='running', attempts=attempts+1, updated_at=? WHERE id=?`, nowUTC(), j.ID); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	j.Status = "running"
	j.Attempts++
	return &j, nil
}

func (r *JobRepo) Done(ctx context.Context, id string) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE jobs SET status='done', updated_at=? WHERE id=?`, nowUTC(), id)
	return err
}

func (r *JobRepo) Fail(ctx context.Context, id, lastErr string, retryAt time.Time, final bool) error {
	status := "pending"
	if final {
		status = "failed"
	}
	_, err := r.DB.ExecContext(ctx, `UPDATE jobs SET status=?, last_error=?, available_at=?, updated_at=? WHERE id=?`,
		status, lastErr, retryAt.UTC().Format(time.RFC3339Nano), nowUTC(), id)
	return err
}

// DeleteByMediaID removes pending/running jobs whose payload references the media id.
func (r *JobRepo) DeleteByMediaID(ctx context.Context, mediaID string) error {
	_, err := r.DB.ExecContext(ctx, `DELETE FROM jobs WHERE payload LIKE ? AND status IN ('pending','running','failed')`, "%"+mediaID+"%")
	return err
}
