package media

import (
	"context"
	"os"
	"time"

	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/internal/storage"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
)

type Service struct {
	Media       *repo.MediaRepo
	Derivatives *repo.DerivativeRepo
	Storage     *storage.Engine
	Jobs        *repo.JobRepo
}

type Item struct {
	MediaID     string     `json:"media_id"`
	MediaType   string     `json:"media_type"`
	MimeType    string     `json:"mime_type"`
	SizeBytes   int64      `json:"size_bytes"`
	Width       *int64     `json:"width,omitempty"`
	Height      *int64     `json:"height,omitempty"`
	DurationMs  *int64     `json:"duration_ms,omitempty"`
	TakenAt     *time.Time `json:"taken_at,omitempty"`
	Status      string     `json:"status"`
	ThumbReady  bool       `json:"thumb_ready"`
	ContentHash string     `json:"content_hash,omitempty"`
	Story       string     `json:"story,omitempty"`
	Title       string     `json:"title,omitempty"`
	PlaceName   string     `json:"place_name,omitempty"`
}

func toItem(m repo.Media, withHash bool) Item {
	it := Item{
		MediaID: m.ID, MediaType: m.MediaType, MimeType: m.MimeType, SizeBytes: m.SizeBytes,
		Width: m.Width, Height: m.Height, DurationMs: m.DurationMs, TakenAt: m.TakenAt,
		Status: m.Status, ThumbReady: m.ThumbReady,
		Story: m.Story, Title: m.Title, PlaceName: m.PlaceName,
	}
	if withHash {
		it.ContentHash = m.ContentHash
	}
	return it
}

func (s *Service) List(ctx context.Context, userID, cursor string, limit int, from, to *time.Time) ([]Item, string, error) {
	list, next, err := s.Media.List(ctx, repo.ListParams{UserID: userID, Cursor: cursor, Limit: limit, From: from, To: to})
	if err != nil {
		return nil, "", err
	}
	out := make([]Item, 0, len(list))
	for _, m := range list {
		out = append(out, toItem(m, false))
	}
	return out, next, nil
}

func (s *Service) Manifest(ctx context.Context, userID, cursor string, limit int) ([]Item, string, error) {
	list, next, err := s.Media.Manifest(ctx, userID, cursor, limit)
	if err != nil {
		return nil, "", err
	}
	out := make([]Item, 0, len(list))
	for _, m := range list {
		out = append(out, toItem(m, true))
	}
	return out, next, nil
}

func (s *Service) Get(ctx context.Context, userID, id string) (*Item, []string, error) {
	m, err := s.Media.ByIDForUser(ctx, userID, id)
	if err != nil {
		return nil, nil, err
	}
	if m == nil {
		return nil, nil, apperr.New(apperr.NotFound, "media not found")
	}
	ok, _ := s.Derivatives.Get(ctx, id, "thumb_sm")
	m.ThumbReady = ok != nil
	kinds, _ := s.Derivatives.ListKinds(ctx, id)
	it := toItem(*m, true)
	return &it, kinds, nil
}

func (s *Service) OriginalPath(ctx context.Context, userID, id string) (absPath, mime string, err error) {
	m, err := s.Media.ByIDForUser(ctx, userID, id)
	if err != nil {
		return "", "", err
	}
	if m == nil {
		return "", "", apperr.New(apperr.NotFound, "media not found")
	}
	abs, err := s.Storage.Abs(m.OriginalPath)
	if err != nil {
		return "", "", err
	}
	if _, err := os.Stat(abs); err != nil {
		return "", "", apperr.New(apperr.NotFound, "file missing")
	}
	return abs, m.MimeType, nil
}

func (s *Service) DerivativePath(ctx context.Context, userID, id, kind string) (absPath string, err error) {
	m, err := s.Media.ByIDForUser(ctx, userID, id)
	if err != nil {
		return "", err
	}
	if m == nil {
		return "", apperr.New(apperr.NotFound, "media not found")
	}
	d, err := s.Derivatives.Get(ctx, id, kind)
	if err != nil {
		return "", err
	}
	if d == nil {
		return "", apperr.New(apperr.DerivativePending, "derivative pending")
	}
	abs, err := s.Storage.Abs(d.Path)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(abs); err != nil {
		return "", apperr.New(apperr.DerivativePending, "derivative missing")
	}
	return abs, nil
}

// ResolveForShare returns file if media id is allowed (caller checks membership).
func (s *Service) ResolveOriginalByID(ctx context.Context, id string) (absPath, mime string, ownerUserID string, err error) {
	m, err := s.Media.ByID(ctx, id)
	if err != nil {
		return "", "", "", err
	}
	if m == nil {
		return "", "", "", apperr.New(apperr.NotFound, "media not found")
	}
	abs, err := s.Storage.Abs(m.OriginalPath)
	if err != nil {
		return "", "", "", err
	}
	return abs, m.MimeType, m.UserID, nil
}

func (s *Service) ResolveDerivativeByID(ctx context.Context, id, kind string) (string, error) {
	d, err := s.Derivatives.Get(ctx, id, kind)
	if err != nil {
		return "", err
	}
	if d == nil {
		return "", apperr.New(apperr.DerivativePending, "derivative pending")
	}
	return s.Storage.Abs(d.Path)
}

type DeleteResult struct {
	Deleted []string `json:"deleted"`
	Missing []string `json:"missing"`
}

// DeleteOne permanently removes one media owned by userID (DB + files).
func (s *Service) DeleteOne(ctx context.Context, userID, id string) error {
	res, err := s.DeleteMany(ctx, userID, []string{id})
	if err != nil {
		return err
	}
	for _, m := range res.Missing {
		if m == id {
			return apperr.New(apperr.NotFound, "media not found")
		}
	}
	return nil
}

// DeleteMany deletes owned media: collect file paths, delete DB rows, then remove files.
func (s *Service) DeleteMany(ctx context.Context, userID string, ids []string) (*DeleteResult, error) {
	if len(ids) == 0 {
		return nil, apperr.New(apperr.BadRequest, "media_ids required")
	}
	out := &DeleteResult{
		Deleted: []string{},
		Missing: []string{},
	}
	seen := map[string]struct{}{}
	for _, id := range ids {
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}

		m, err := s.Media.ByIDForUser(ctx, userID, id)
		if err != nil {
			return nil, err
		}
		if m == nil {
			out.Missing = append(out.Missing, id)
			continue
		}

		relPaths := []string{m.OriginalPath}
		derivs, err := s.Derivatives.ListByMedia(ctx, id)
		if err != nil {
			return nil, err
		}
		for _, d := range derivs {
			relPaths = append(relPaths, d.Path)
		}

		ok, err := s.Media.DeleteForUser(ctx, userID, id)
		if err != nil {
			return nil, err
		}
		if !ok {
			out.Missing = append(out.Missing, id)
			continue
		}
		if s.Jobs != nil {
			_ = s.Jobs.DeleteByMediaID(ctx, id)
		}
		for _, rel := range relPaths {
			if rel == "" {
				continue
			}
			abs, err := s.Storage.Abs(rel)
			if err != nil {
				continue
			}
			if err := os.Remove(abs); err != nil && !os.IsNotExist(err) {
				// best-effort; DB already cleaned — keep going
				_ = err
			}
		}
		out.Deleted = append(out.Deleted, id)
	}
	return out, nil
}

type CaptionPatch struct {
	Story     *string `json:"story"`
	Title     *string `json:"title"`
	PlaceName *string `json:"place_name"`
}

func (s *Service) PatchCaption(ctx context.Context, userID, id string, p CaptionPatch) (*Item, error) {
	if p.Story == nil && p.Title == nil && p.PlaceName == nil {
		return nil, apperr.New(apperr.BadRequest, "no fields to update")
	}
	if p.Story != nil && len([]rune(*p.Story)) > 8000 {
		return nil, apperr.New(apperr.BadRequest, "story too long")
	}
	if p.Title != nil && len([]rune(*p.Title)) > 200 {
		return nil, apperr.New(apperr.BadRequest, "title too long")
	}
	if p.PlaceName != nil && len([]rune(*p.PlaceName)) > 200 {
		return nil, apperr.New(apperr.BadRequest, "place_name too long")
	}
	ok, err := s.Media.UpdateCaption(ctx, userID, id, repo.MediaCaptionUpdate{
		Story: p.Story, Title: p.Title, PlaceName: p.PlaceName,
	})
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, apperr.New(apperr.NotFound, "media not found")
	}
	m, err := s.Media.ByIDForUser(ctx, userID, id)
	if err != nil {
		return nil, err
	}
	if m == nil {
		return nil, apperr.New(apperr.NotFound, "media not found")
	}
	it := toItem(*m, true)
	return &it, nil
}

type StoryAIResult struct {
	Story  string `json:"story"`
	Title  string `json:"title,omitempty"`
	Source string `json:"source"` // template | llm
}

// GenerateStoryDraft returns a draft without writing to DB (首期模板文案).
func (s *Service) GenerateStoryDraft(ctx context.Context, userID, id string) (*StoryAIResult, error) {
	m, err := s.Media.ByIDForUser(ctx, userID, id)
	if err != nil {
		return nil, err
	}
	if m == nil {
		return nil, apperr.New(apperr.NotFound, "media not found")
	}
	place := m.PlaceName
	if place == "" {
		place = "某个安静的角落"
	}
	when := "那一天"
	if m.TakenAt != nil {
		when = m.TakenAt.Local().Format("2006年1月2日")
	}
	title := m.Title
	if title == "" {
		if m.MediaType == "video" {
			title = "一段被收藏的时光"
		} else {
			title = "光影里的片刻"
		}
	}
	story := "「在" + when + "，于" + place + "停下脚步。风轻轻走过，把这一刻写进 MemoryStore。」"
	return &StoryAIResult{Story: story, Title: title, Source: "template"}, nil
}
