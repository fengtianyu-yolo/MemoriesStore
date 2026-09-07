package repo

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type Session struct {
	ID                string
	UserID            string
	AccessTokenHash   string
	RefreshTokenHash  string
	ExpiresAt         time.Time
	RefreshExpiresAt  time.Time
	RevokedAt         *time.Time
	CreatedAt         time.Time
	UserAgent         string
	DeviceID          string
}

type SessionRepo struct{ DB *sql.DB }

func (r *SessionRepo) Create(ctx context.Context, s *Session) error {
	var refreshExp any
	if !s.RefreshExpiresAt.IsZero() {
		refreshExp = s.RefreshExpiresAt.UTC().Format(time.RFC3339Nano)
	}
	_, err := r.DB.ExecContext(ctx, `INSERT INTO sessions(id, user_id, access_token_hash, refresh_token_hash, expires_at, refresh_expires_at, created_at, user_agent, device_id)
		VALUES(?,?,?,?,?,?,?,?,?)`,
		s.ID, s.UserID, s.AccessTokenHash, nullStr(s.RefreshTokenHash),
		s.ExpiresAt.UTC().Format(time.RFC3339Nano), refreshExp, nowUTC(), nullStr(s.UserAgent), nullStr(s.DeviceID))
	return err
}

func (r *SessionRepo) ByAccessHash(ctx context.Context, hash string) (*Session, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, access_token_hash, COALESCE(refresh_token_hash,''), expires_at, refresh_expires_at, revoked_at, created_at, COALESCE(user_agent,''), COALESCE(device_id,'')
		FROM sessions WHERE access_token_hash = ?`, hash)
	return scanSession(row)
}

func (r *SessionRepo) ByRefreshHash(ctx context.Context, hash string) (*Session, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, access_token_hash, COALESCE(refresh_token_hash,''), expires_at, refresh_expires_at, revoked_at, created_at, COALESCE(user_agent,''), COALESCE(device_id,'')
		FROM sessions WHERE refresh_token_hash = ?`, hash)
	return scanSession(row)
}

func (r *SessionRepo) Revoke(ctx context.Context, id string) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, nowUTC(), id)
	return err
}

func (r *SessionRepo) RotateTokens(ctx context.Context, id, accessHash, refreshHash string, accessExp, refreshExp time.Time) error {
	_, err := r.DB.ExecContext(ctx, `UPDATE sessions SET access_token_hash=?, refresh_token_hash=?, expires_at=?, refresh_expires_at=? WHERE id=? AND revoked_at IS NULL`,
		accessHash, refreshHash,
		accessExp.UTC().Format(time.RFC3339Nano),
		refreshExp.UTC().Format(time.RFC3339Nano),
		id)
	return err
}

func scanSession(row *sql.Row) (*Session, error) {
	var s Session
	var exp, created string
	var refreshExp, revoked sql.NullString
	err := row.Scan(&s.ID, &s.UserID, &s.AccessTokenHash, &s.RefreshTokenHash, &exp, &refreshExp, &revoked, &created, &s.UserAgent, &s.DeviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.ExpiresAt, _ = time.Parse(time.RFC3339Nano, exp)
	s.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	if refreshExp.Valid {
		s.RefreshExpiresAt, _ = time.Parse(time.RFC3339Nano, refreshExp.String)
	}
	if revoked.Valid {
		t, _ := time.Parse(time.RFC3339Nano, revoked.String)
		s.RevokedAt = &t
	}
	return &s, nil
}
