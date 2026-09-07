package repo

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type User struct {
	ID           string
	Username     string
	PasswordHash string
	Phone        string
	DisplayName  string
	Status       string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type UserRepo struct{ DB *sql.DB }

func (r *UserRepo) Create(ctx context.Context, u *User) error {
	now := nowUTC()
	_, err := r.DB.ExecContext(ctx, `INSERT INTO users(id, username, password_hash, phone, display_name, status, created_at, updated_at)
		VALUES(?,?,?,?,?,?,?,?)`,
		u.ID, u.Username, nullStr(u.PasswordHash), nullStr(u.Phone), u.DisplayName, u.Status, now, now)
	return err
}

func (r *UserRepo) ByUsername(ctx context.Context, username string) (*User, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, username, COALESCE(password_hash,''), COALESCE(phone,''), display_name, status, created_at, updated_at
		FROM users WHERE username = ?`, username)
	return scanUser(row)
}

func (r *UserRepo) ByID(ctx context.Context, id string) (*User, error) {
	row := r.DB.QueryRowContext(ctx, `SELECT id, username, COALESCE(password_hash,''), COALESCE(phone,''), display_name, status, created_at, updated_at
		FROM users WHERE id = ?`, id)
	return scanUser(row)
}

func scanUser(row *sql.Row) (*User, error) {
	var u User
	var created, updated string
	err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.Phone, &u.DisplayName, &u.Status, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	u.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
	return &u, nil
}
