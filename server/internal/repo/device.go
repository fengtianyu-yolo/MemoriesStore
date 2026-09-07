package repo

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type Device struct {
	ID              string
	UserID          string
	Name            string
	Platform        string
	ClientDeviceKey string
	LastSeenAt      *time.Time
	RevokedAt       *time.Time
	CreatedAt       time.Time
}

type DeviceRepo struct{ DB *sql.DB }

func (r *DeviceRepo) UpsertByClientKey(ctx context.Context, d *Device) error {
	if d.ClientDeviceKey == "" {
		now := nowUTC()
		_, err := r.DB.ExecContext(ctx, `INSERT INTO devices(id, user_id, name, platform, client_device_key, last_seen_at, created_at)
			VALUES(?,?,?,?,?,?,?)`, d.ID, d.UserID, d.Name, d.Platform, nil, now, now)
		return err
	}
	existing, err := r.ByClientKey(ctx, d.UserID, d.ClientDeviceKey)
	if err != nil {
		return err
	}
	now := nowUTC()
	if existing != nil {
		d.ID = existing.ID
		_, err = r.DB.ExecContext(ctx, `UPDATE devices SET name=?, platform=?, last_seen_at=?, revoked_at=NULL WHERE id=?`,
			d.Name, d.Platform, now, d.ID)
		return err
	}
	_, err = r.DB.ExecContext(ctx, `INSERT INTO devices(id, user_id, name, platform, client_device_key, last_seen_at, created_at)
		VALUES(?,?,?,?,?,?,?)`, d.ID, d.UserID, d.Name, d.Platform, d.ClientDeviceKey, now, now)
	return err
}

func (r *DeviceRepo) ByClientKey(ctx context.Context, userID, key string) (*Device, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, user_id, name, platform, COALESCE(client_device_key,''), last_seen_at, revoked_at, created_at
		FROM devices WHERE user_id=? AND client_device_key=?`, userID, key)
	return scanDevice(row)
}

func (r *DeviceRepo) ByUser(ctx context.Context, userID string) ([]Device, error) {
	rows, err := r.DB.QueryContext(ctx, `SELECT id, user_id, name, platform, COALESCE(client_device_key,''), last_seen_at, revoked_at, created_at
		FROM devices WHERE user_id=? ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d, err := scanDeviceRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

func (r *DeviceRepo) Revoke(ctx context.Context, userID, id string) error {
	res, err := r.DB.ExecContext(ctx, `UPDATE devices SET revoked_at=? WHERE id=? AND user_id=? AND revoked_at IS NULL`, nowUTC(), id, userID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func scanDevice(row *sql.Row) (*Device, error) {
	var d Device
	var lastSeen, revoked sql.NullString
	var created string
	err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.ClientDeviceKey, &lastSeen, &revoked, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	if lastSeen.Valid {
		t, _ := time.Parse(time.RFC3339Nano, lastSeen.String)
		d.LastSeenAt = &t
	}
	if revoked.Valid {
		t, _ := time.Parse(time.RFC3339Nano, revoked.String)
		d.RevokedAt = &t
	}
	return &d, nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanDeviceRow(row rowScanner) (*Device, error) {
	var d Device
	var lastSeen, revoked sql.NullString
	var created string
	if err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.ClientDeviceKey, &lastSeen, &revoked, &created); err != nil {
		return nil, err
	}
	d.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	if lastSeen.Valid {
		t, _ := time.Parse(time.RFC3339Nano, lastSeen.String)
		d.LastSeenAt = &t
	}
	if revoked.Valid {
		t, _ := time.Parse(time.RFC3339Nano, revoked.String)
		d.RevokedAt = &t
	}
	return &d, nil
}
