package repo

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

type Media struct {
	ID             string
	UserID         string
	ContentHash    string
	MimeType       string
	MediaType      string
	SizeBytes      int64
	Width          *int64
	Height         *int64
	DurationMs     *int64
	TakenAt        *time.Time
	OriginalPath   string
	Status         string
	SourceDeviceID string
	Story          string
	Title          string
	PlaceName      string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	ThumbReady     bool
}

type MediaRepo struct{ DB *sql.DB }

func (r *MediaRepo) Create(ctx context.Context, m *Media) error {
	var taken any
	if m.TakenAt != nil {
		taken = m.TakenAt.UTC().Format(time.RFC3339Nano)
	}
	now := nowUTC()
	_, err := r.DB.ExecContext(ctx, `INSERT INTO media(id, user_id, content_hash, mime_type, media_type, size_bytes, width, height, duration_ms, taken_at, original_path, status, source_device_id, created_at, updated_at)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		m.ID, m.UserID, m.ContentHash, m.MimeType, m.MediaType, m.SizeBytes,
		nullInt(m.Width), nullInt(m.Height), nullInt(m.DurationMs), taken,
		m.OriginalPath, m.Status, nullStr(m.SourceDeviceID), now, now)
	return err
}

func nullInt(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

func (r *MediaRepo) ByUserHash(ctx context.Context, userID, hash string) (*Media, error) {
	row := r.DB.QueryRowContext(ctx, mediaSelect+` WHERE user_id=? AND content_hash=?`, userID, hash)
	return scanMedia(row)
}

func (r *MediaRepo) ByIDForUser(ctx context.Context, userID, id string) (*Media, error) {
	row := r.DB.QueryRowContext(ctx, mediaSelect+` WHERE id=? AND user_id=?`, id, userID)
	return scanMedia(row)
}

func (r *MediaRepo) ByID(ctx context.Context, id string) (*Media, error) {
	row := r.DB.QueryRowContext(ctx, mediaSelect+` WHERE id=?`, id)
	return scanMedia(row)
}

func (r *MediaRepo) UpdateStatus(ctx context.Context, id, status string) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE media SET status=?, updated_at=? WHERE id=?`, status, nowUTC(), id)
	return err
}

// DeleteForUser removes the media row if it belongs to userID. Returns false if not found / not owned.
func (r *MediaRepo) DeleteForUser(ctx context.Context, userID, id string) (bool, error) {
	res, err := r.DB.ExecContext(ctx, `DELETE FROM media WHERE id=? AND user_id=?`, id, userID)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

type MediaCaptionUpdate struct {
	Story     *string
	Title     *string
	PlaceName *string
}

func (r *MediaRepo) UpdateCaption(ctx context.Context, userID, id string, u MediaCaptionUpdate) (bool, error) {
	sets := []string{}
	args := []any{}
	if u.Story != nil {
		sets = append(sets, "story=?")
		args = append(args, *u.Story)
	}
	if u.Title != nil {
		sets = append(sets, "title=?")
		args = append(args, *u.Title)
	}
	if u.PlaceName != nil {
		sets = append(sets, "place_name=?")
		args = append(args, *u.PlaceName)
	}
	if len(sets) == 0 {
		return true, nil
	}
	sets = append(sets, "updated_at=?")
	args = append(args, nowUTC(), id, userID)
	q := `UPDATE media SET ` + strings.Join(sets, ", ") + ` WHERE id=? AND user_id=?`
	res, err := r.DB.ExecContext(ctx, q, args...)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func (r *MediaRepo) ExistsHashes(ctx context.Context, userID string, hashes []string) (map[string]*Media, error) {
	out := map[string]*Media{}
	if len(hashes) == 0 {
		return out, nil
	}
	placeholders := make([]string, len(hashes))
	args := make([]any, 0, len(hashes)+1)
	args = append(args, userID)
	for i, h := range hashes {
		placeholders[i] = "?"
		args = append(args, h)
	}
	q := mediaSelect + ` WHERE user_id=? AND content_hash IN (` + strings.Join(placeholders, ",") + `)`
	rows, err := r.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		m, err := scanMediaRow(rows)
		if err != nil {
			return nil, err
		}
		out[m.ContentHash] = m
	}
	return out, rows.Err()
}

type ListParams struct {
	UserID string
	Limit  int
	Cursor string // taken_at|id
	From   *time.Time
	To     *time.Time
}

func (r *MediaRepo) List(ctx context.Context, p ListParams) ([]Media, string, error) {
	if p.Limit <= 0 || p.Limit > 500 {
		p.Limit = 100
	}
	var args []any
	var b strings.Builder
	b.WriteString(mediaSelect)
	b.WriteString(` WHERE user_id=?`)
	args = append(args, p.UserID)
	if p.From != nil {
		b.WriteString(` AND taken_at >= ?`)
		args = append(args, p.From.UTC().Format(time.RFC3339Nano))
	}
	if p.To != nil {
		b.WriteString(` AND taken_at <= ?`)
		args = append(args, p.To.UTC().Format(time.RFC3339Nano))
	}
	if p.Cursor != "" {
		parts := strings.SplitN(p.Cursor, "|", 2)
		if len(parts) == 2 {
			b.WriteString(` AND (taken_at < ? OR (taken_at = ? AND id < ?))`)
			args = append(args, parts[0], parts[0], parts[1])
		}
	}
	b.WriteString(` ORDER BY taken_at DESC, id DESC LIMIT ?`)
	args = append(args, p.Limit+1)
	rows, err := r.DB.QueryContext(ctx, b.String(), args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	var list []Media
	for rows.Next() {
		m, err := scanMediaRow(rows)
		if err != nil {
			return nil, "", err
		}
		list = append(list, *m)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}
	var next string
	if len(list) > p.Limit {
		list = list[:p.Limit]
		last := list[len(list)-1]
		taken := ""
		if last.TakenAt != nil {
			taken = last.TakenAt.UTC().Format(time.RFC3339Nano)
		}
		next = fmt.Sprintf("%s|%s", taken, last.ID)
	}
	// thumb ready flags
	for i := range list {
		ok, _ := r.hasDerivative(ctx, list[i].ID, "thumb_sm")
		list[i].ThumbReady = ok
	}
	return list, next, nil
}

func (r *MediaRepo) Manifest(ctx context.Context, userID, cursor string, limit int) ([]Media, string, error) {
	return r.List(ctx, ListParams{UserID: userID, Cursor: cursor, Limit: limit})
}

func (r *MediaRepo) hasDerivative(ctx context.Context, mediaID, kind string) (bool, error) {
	var id string
	err := r.DB.QueryRowContext(ctx, `SELECT id FROM media_derivatives WHERE media_id=? AND kind=?`, mediaID, kind).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (r *MediaRepo) SumSizeByUser(ctx context.Context, userID string) (int64, int64, error) {
	var sum sql.NullInt64
	var cnt int64
	err := r.DB.QueryRowContext(ctx, `SELECT SUM(size_bytes), COUNT(*) FROM media WHERE user_id=?`, userID).Scan(&sum, &cnt)
	if err != nil {
		return 0, 0, err
	}
	if sum.Valid {
		return sum.Int64, cnt, nil
	}
	return 0, cnt, nil
}

const mediaSelect = `SELECT id, user_id, content_hash, mime_type, media_type, size_bytes, width, height, duration_ms, taken_at, original_path, status, COALESCE(source_device_id,''), COALESCE(story,''), COALESCE(title,''), COALESCE(place_name,''), created_at, updated_at FROM media`

func scanMedia(row *sql.Row) (*Media, error) {
	m, err := scanMediaRow(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return m, err
}

func scanMediaRow(row rowScanner) (*Media, error) {
	var m Media
	var w, h, dur sql.NullInt64
	var created, updated sql.NullString
	var takenStr sql.NullString
	err := row.Scan(&m.ID, &m.UserID, &m.ContentHash, &m.MimeType, &m.MediaType, &m.SizeBytes, &w, &h, &dur, &takenStr, &m.OriginalPath, &m.Status, &m.SourceDeviceID, &m.Story, &m.Title, &m.PlaceName, &created, &updated)
	if err != nil {
		return nil, err
	}
	m.Width = fromNullInt(w)
	m.Height = fromNullInt(h)
	m.DurationMs = fromNullInt(dur)
	if takenStr.Valid && takenStr.String != "" {
		t, _ := time.Parse(time.RFC3339Nano, takenStr.String)
		m.TakenAt = &t
	}
	if created.Valid {
		m.CreatedAt, _ = time.Parse(time.RFC3339Nano, created.String)
	}
	if updated.Valid {
		m.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated.String)
	}
	return &m, nil
}

type Derivative struct {
	ID        string
	MediaID   string
	Kind      string
	Path      string
	Width     *int64
	Height    *int64
	SizeBytes *int64
}

type DerivativeRepo struct{ DB *sql.DB }

func (r *DerivativeRepo) Upsert(ctx context.Context, d *Derivative) error {
	_, err := r.DB.ExecContext(ctx, `INSERT INTO media_derivatives(id, media_id, kind, path, width, height, size_bytes)
		VALUES(?,?,?,?,?,?,?)
		ON CONFLICT(media_id, kind) DO UPDATE SET path=excluded.path, width=excluded.width, height=excluded.height, size_bytes=excluded.size_bytes`,
		d.ID, d.MediaID, d.Kind, d.Path, nullInt(d.Width), nullInt(d.Height), nullInt(d.SizeBytes))
	return err
}

func (r *DerivativeRepo) Get(ctx context.Context, mediaID, kind string) (*Derivative, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, media_id, kind, path, width, height, size_bytes FROM media_derivatives WHERE media_id=? AND kind=?`, mediaID, kind)
	var d Derivative
	var w, h, sz sql.NullInt64
	err := row.Scan(&d.ID, &d.MediaID, &d.Kind, &d.Path, &w, &h, &sz)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d.Width = fromNullInt(w)
	d.Height = fromNullInt(h)
	d.SizeBytes = fromNullInt(sz)
	return &d, nil
}

func (r *DerivativeRepo) ListKinds(ctx context.Context, mediaID string) ([]string, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT kind FROM media_derivatives WHERE media_id=?`, mediaID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var kinds []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		kinds = append(kinds, k)
	}
	return kinds, rows.Err()
}

func (r *DerivativeRepo) ListByMedia(ctx context.Context, mediaID string) ([]Derivative, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT id, media_id, kind, path, width, height, size_bytes FROM media_derivatives WHERE media_id=?`, mediaID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Derivative
	for rows.Next() {
		var d Derivative
		var w, h, sz sql.NullInt64
		if err := rows.Scan(&d.ID, &d.MediaID, &d.Kind, &d.Path, &w, &h, &sz); err != nil {
			return nil, err
		}
		d.Width = fromNullInt(w)
		d.Height = fromNullInt(h)
		d.SizeBytes = fromNullInt(sz)
		out = append(out, d)
	}
	return out, rows.Err()
}
