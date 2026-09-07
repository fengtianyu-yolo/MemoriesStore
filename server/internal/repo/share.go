package repo

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type ShareLink struct {
	ID            string
	UserID        string
	TokenHash     string
	Title         string
	ScopeType     string
	ScopePayload  string
	PasswordHash  string
	ExpiresAt     *time.Time
	RevokedAt     *time.Time
	CreatedAt     time.Time
}

type ShareRepo struct{ DB *sql.DB }

func (r *ShareRepo) Create(ctx context.Context, s *ShareLink) error {
	var exp any
	if s.ExpiresAt != nil {
		exp = s.ExpiresAt.UTC().Format(time.RFC3339Nano)
	}
	_, err := r.DB.ExecContext(ctx, `INSERT INTO share_links(id, user_id, token_hash, title, scope_type, scope_payload, password_hash, expires_at, created_at)
		VALUES(?,?,?,?,?,?,?,?,?)`,
		s.ID, s.UserID, s.TokenHash, s.Title, s.ScopeType, s.ScopePayload, nullStr(s.PasswordHash), exp, nowUTC())
	return err
}

func (r *ShareRepo) ByTokenHash(ctx context.Context, hash string) (*ShareLink, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, token_hash, title, scope_type, scope_payload, COALESCE(password_hash,''), expires_at, revoked_at, created_at
		FROM share_links WHERE token_hash=?`, hash)
	return scanShare(row)
}

func (r *ShareRepo) ByUser(ctx context.Context, userID string) ([]ShareLink, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT id, user_id, token_hash, title, scope_type, scope_payload, COALESCE(password_hash,''), expires_at, revoked_at, created_at
		FROM share_links WHERE user_id=? ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ShareLink
	for rows.Next() {
		s, err := scanShareRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

func (r *ShareRepo) Revoke(ctx context.Context, userID, id string) error {
	res, err := r.DB.ExecContext(ctx, `UPDATE share_links SET revoked_at=? WHERE id=? AND user_id=? AND revoked_at IS NULL`, nowUTC(), id, userID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (r *ShareRepo) ByIDForUser(ctx context.Context, userID, id string) (*ShareLink, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, token_hash, title, scope_type, scope_payload, COALESCE(password_hash,''), expires_at, revoked_at, created_at
		FROM share_links WHERE id=? AND user_id=?`, id, userID)
	return scanShare(row)
}

func scanShare(row *sql.Row) (*ShareLink, error) {
	s, err := scanShareRow(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return s, err
}

func scanShareRow(row rowScanner) (*ShareLink, error) {
	var s ShareLink
	var exp, rev, created sql.NullString
	err := row.Scan(&s.ID, &s.UserID, &s.TokenHash, &s.Title, &s.ScopeType, &s.ScopePayload, &s.PasswordHash, &exp, &rev, &created)
	if err != nil {
		return nil, err
	}
	if exp.Valid && exp.String != "" {
		t, _ := time.Parse(time.RFC3339Nano, exp.String)
		s.ExpiresAt = &t
	}
	if rev.Valid && rev.String != "" {
		t, _ := time.Parse(time.RFC3339Nano, rev.String)
		s.RevokedAt = &t
	}
	if created.Valid {
		s.CreatedAt, _ = time.Parse(time.RFC3339Nano, created.String)
	}
	return &s, nil
}

type InviteRepo struct{ DB *sql.DB }

func (r *InviteRepo) Consume(ctx context.Context, code string) error {
	tx, err := r.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var maxUses, used int
	var exp sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT max_uses, used_count, expires_at FROM invite_codes WHERE code=?`, code).Scan(&maxUses, &used, &exp)
	if errors.Is(err, sql.ErrNoRows) {
		return sql.ErrNoRows
	}
	if err != nil {
		return err
	}
	if exp.Valid && exp.String != "" {
		t, _ := time.Parse(time.RFC3339Nano, exp.String)
		if time.Now().UTC().After(t) {
			return sql.ErrNoRows
		}
	}
	if used >= maxUses {
		return sql.ErrNoRows
	}
	if _, err := tx.ExecContext(ctx, `UPDATE invite_codes SET used_count = used_count + 1 WHERE code=?`, code); err != nil {
		return err
	}
	return tx.Commit()
}
