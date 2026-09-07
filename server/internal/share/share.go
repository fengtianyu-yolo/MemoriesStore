package share

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/fengtianyu/memorystore/server/internal/config"
	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/fengtianyu/memorystore/server/pkg/hashutil"
	"github.com/fengtianyu/memorystore/server/pkg/ids"
	"github.com/fengtianyu/memorystore/server/pkg/passwd"
)

type Service struct {
	Shares *repo.ShareRepo
	Media  *repo.MediaRepo
	Cfg    config.ShareConfig
	BaseURL string
}

type CreateInput struct {
	Title         string   `json:"title"`
	ScopeType     string   `json:"scope_type"`
	MediaIDs      []string `json:"media_ids"`
	ExpiresInDays int      `json:"expires_in_days"`
	Password      string   `json:"password"`
}

type CreateResult struct {
	ShareID   string     `json:"share_id"`
	URL       string     `json:"url"`
	Token     string     `json:"token"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
}

func (s *Service) Create(ctx context.Context, userID string, in CreateInput) (*CreateResult, error) {
	if in.ScopeType == "" {
		in.ScopeType = "media_ids"
	}
	if in.ScopeType != "media_ids" {
		return nil, apperr.New(apperr.BadRequest, "only media_ids scope supported")
	}
	if len(in.MediaIDs) == 0 {
		return nil, apperr.New(apperr.BadRequest, "media_ids required")
	}
	if len(in.MediaIDs) > 2000 {
		return nil, apperr.New(apperr.BadRequest, "too many media_ids")
	}
	for _, id := range in.MediaIDs {
		m, err := s.Media.ByIDForUser(ctx, userID, id)
		if err != nil {
			return nil, err
		}
		if m == nil {
			return nil, apperr.New(apperr.ShareScopeInvalid, "media not found in your library")
		}
	}
	days := in.ExpiresInDays
	if days <= 0 {
		days = s.Cfg.DefaultTTLDays
	}
	exp := time.Now().UTC().Add(time.Duration(days) * 24 * time.Hour)
	token, err := hashutil.RandomToken(24)
	if err != nil {
		return nil, err
	}
	payload, _ := json.Marshal(map[string]any{"media_ids": in.MediaIDs})
	var pwHash string
	if in.Password != "" {
		pwHash, err = passwd.Hash(in.Password)
		if err != nil {
			return nil, err
		}
	}
	link := &repo.ShareLink{
		ID:           ids.New(),
		UserID:       userID,
		TokenHash:    hashutil.SHA256String(token),
		Title:        in.Title,
		ScopeType:    in.ScopeType,
		ScopePayload: string(payload),
		PasswordHash: pwHash,
		ExpiresAt:    &exp,
	}
	if err := s.Shares.Create(ctx, link); err != nil {
		return nil, err
	}
	url := s.BaseURL + "/s/" + token
	return &CreateResult{ShareID: link.ID, URL: url, Token: token, ExpiresAt: &exp}, nil
}

func (s *Service) List(ctx context.Context, userID string) ([]repo.ShareLink, error) {
	return s.Shares.ByUser(ctx, userID)
}

func (s *Service) Revoke(ctx context.Context, userID, id string) error {
	if err := s.Shares.Revoke(ctx, userID, id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return apperr.New(apperr.NotFound, "share not found")
		}
		return err
	}
	return nil
}

type ResolvedShare struct {
	Link     *repo.ShareLink
	MediaIDs []string
}

func (s *Service) ResolveToken(ctx context.Context, token, password string) (*ResolvedShare, error) {
	link, err := s.Shares.ByTokenHash(ctx, hashutil.SHA256String(token))
	if err != nil {
		return nil, err
	}
	if link == nil {
		return nil, apperr.New(apperr.ShareInvalid, "invalid share token")
	}
	if link.RevokedAt != nil {
		return nil, apperr.New(apperr.ShareRevoked, "share revoked")
	}
	if link.ExpiresAt != nil && time.Now().UTC().After(*link.ExpiresAt) {
		return nil, apperr.New(apperr.ShareExpired, "share expired")
	}
	if link.PasswordHash != "" {
		ok, err := passwd.Verify(link.PasswordHash, password)
		if err != nil || !ok {
			return nil, apperr.New(apperr.SharePasswordRequired, "password required or invalid")
		}
	}
	var payload struct {
		MediaIDs []string `json:"media_ids"`
	}
	_ = json.Unmarshal([]byte(link.ScopePayload), &payload)
	return &ResolvedShare{Link: link, MediaIDs: payload.MediaIDs}, nil
}

func (s *Service) Allows(rs *ResolvedShare, mediaID string) bool {
	for _, id := range rs.MediaIDs {
		if id == mediaID {
			return true
		}
	}
	return false
}
