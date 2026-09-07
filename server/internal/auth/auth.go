package auth

import (
	"context"
	"database/sql"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/fengtianyu/memorystore/server/internal/config"
	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/fengtianyu/memorystore/server/pkg/hashutil"
	"github.com/fengtianyu/memorystore/server/pkg/ids"
	"github.com/fengtianyu/memorystore/server/pkg/passwd"
)

type Service struct {
	Users    *repo.UserRepo
	Sessions *repo.SessionRepo
	Invites  *repo.InviteRepo
	Cfg      config.AuthConfig
}

type TokenPair struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	ExpiresAt    time.Time `json:"expires_at"`
}

type UserDTO struct {
	ID          string `json:"id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
}

type LoginResult struct {
	User   UserDTO   `json:"user"`
	Tokens TokenPair `json:"-"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresAt    time.Time `json:"expires_at"`
}

func (s *Service) Register(ctx context.Context, username, password, displayName, inviteCode string) error {
	username = strings.TrimSpace(username)
	if username == "" || utf8.RuneCountInString(password) < s.Cfg.PasswordMinLength {
		return apperr.New(apperr.BadRequest, "invalid username or password too short")
	}
	switch s.Cfg.RegisterMode {
	case "closed":
		return apperr.New(apperr.RegisterDisabled, "registration is disabled")
	case "invite":
		if inviteCode == "" {
			return apperr.New(apperr.InviteInvalid, "invite code required")
		}
		if err := s.Invites.Consume(ctx, inviteCode); err != nil {
			return apperr.New(apperr.InviteInvalid, "invalid invite code")
		}
	}
	existing, err := s.Users.ByUsername(ctx, username)
	if err != nil {
		return err
	}
	if existing != nil {
		return apperr.New(apperr.UsernameTaken, "username already taken")
	}
	hash, err := passwd.Hash(password)
	if err != nil {
		return err
	}
	if displayName == "" {
		displayName = username
	}
	u := &repo.User{
		ID:           ids.New(),
		Username:     username,
		PasswordHash: hash,
		DisplayName:  displayName,
		Status:       "active",
	}
	if err := s.Users.Create(ctx, u); err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return apperr.New(apperr.UsernameTaken, "username already taken")
		}
		return err
	}
	return nil
}

func (s *Service) Login(ctx context.Context, username, password, userAgent string) (*LoginResult, error) {
	u, err := s.Users.ByUsername(ctx, strings.TrimSpace(username))
	if err != nil {
		return nil, err
	}
	if u == nil || u.Status != "active" {
		return nil, apperr.New(apperr.AuthInvalidCredentials, "invalid credentials")
	}
	ok, err := passwd.Verify(u.PasswordHash, password)
	if err != nil || !ok {
		return nil, apperr.New(apperr.AuthInvalidCredentials, "invalid credentials")
	}
	return s.issueTokens(ctx, u, userAgent, "")
}

func (s *Service) issueTokens(ctx context.Context, u *repo.User, userAgent, deviceID string) (*LoginResult, error) {
	access, err := hashutil.RandomToken(32)
	if err != nil {
		return nil, err
	}
	refresh, err := hashutil.RandomToken(32)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	sess := &repo.Session{
		ID:               ids.New(),
		UserID:           u.ID,
		AccessTokenHash:  hashutil.SHA256String(access),
		RefreshTokenHash: hashutil.SHA256String(refresh),
		ExpiresAt:        now.Add(s.Cfg.AccessTTL()),
		RefreshExpiresAt: now.Add(s.Cfg.RefreshTTL()),
		UserAgent:        userAgent,
		DeviceID:         deviceID,
	}
	if err := s.Sessions.Create(ctx, sess); err != nil {
		return nil, err
	}
	return &LoginResult{
		User: UserDTO{ID: u.ID, Username: u.Username, DisplayName: u.DisplayName},
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresAt:    sess.ExpiresAt,
	}, nil
}

type AuthedUser struct {
	UserID    string
	SessionID string
	Username  string
	Display   string
}

func (s *Service) Authenticate(ctx context.Context, accessToken string) (*AuthedUser, error) {
	if accessToken == "" {
		return nil, apperr.New(apperr.Unauthorized, "missing token")
	}
	hash := hashutil.SHA256String(accessToken)
	sess, err := s.Sessions.ByAccessHash(ctx, hash)
	if err != nil {
		return nil, err
	}
	if sess == nil || sess.RevokedAt != nil || time.Now().UTC().After(sess.ExpiresAt) {
		return nil, apperr.New(apperr.Unauthorized, "invalid or expired token")
	}
	u, err := s.Users.ByID(ctx, sess.UserID)
	if err != nil {
		return nil, err
	}
	if u == nil || u.Status != "active" {
		return nil, apperr.New(apperr.UserDisabled, "user disabled")
	}
	return &AuthedUser{UserID: u.ID, SessionID: sess.ID, Username: u.Username, Display: u.DisplayName}, nil
}

func (s *Service) Refresh(ctx context.Context, refreshToken string) (*LoginResult, error) {
	hash := hashutil.SHA256String(refreshToken)
	sess, err := s.Sessions.ByRefreshHash(ctx, hash)
	if err != nil {
		return nil, err
	}
	if sess == nil || sess.RevokedAt != nil || time.Now().UTC().After(sess.RefreshExpiresAt) {
		return nil, apperr.New(apperr.Unauthorized, "invalid refresh token")
	}
	u, err := s.Users.ByID(ctx, sess.UserID)
	if err != nil {
		return nil, err
	}
	if u == nil || u.Status != "active" {
		return nil, apperr.New(apperr.UserDisabled, "user disabled")
	}
	access, err := hashutil.RandomToken(32)
	if err != nil {
		return nil, err
	}
	refresh, err := hashutil.RandomToken(32)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	accessExp := now.Add(s.Cfg.AccessTTL())
	refreshExp := now.Add(s.Cfg.RefreshTTL())
	if err := s.Sessions.RotateTokens(ctx, sess.ID, hashutil.SHA256String(access), hashutil.SHA256String(refresh), accessExp, refreshExp); err != nil {
		return nil, err
	}
	return &LoginResult{
		User:         UserDTO{ID: u.ID, Username: u.Username, DisplayName: u.DisplayName},
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresAt:    accessExp,
	}, nil
}

func (s *Service) Logout(ctx context.Context, sessionID string) error {
	return s.Sessions.Revoke(ctx, sessionID)
}

func (s *Service) Me(ctx context.Context, userID string) (*UserDTO, error) {
	u, err := s.Users.ByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if u == nil {
		return nil, apperr.New(apperr.NotFound, "user not found")
	}
	return &UserDTO{ID: u.ID, Username: u.Username, DisplayName: u.DisplayName}, nil
}

// EnsureInviteRepo helps when invites table unused in open mode.
func EnsureInviteRepo(db *sql.DB) *repo.InviteRepo {
	return &repo.InviteRepo{DB: db}
}
