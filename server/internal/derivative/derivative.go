package derivative

import (
	"context"
	"encoding/json"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/fengtianyu/memorystore/server/internal/config"
	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/internal/storage"
	"github.com/fengtianyu/memorystore/server/pkg/ids"
	"github.com/nfnt/resize"
	"image/jpeg"
)

type Service struct {
	Media       *repo.MediaRepo
	Derivatives *repo.DerivativeRepo
	Storage     *storage.Engine
	Cfg         config.DerivativeConfig
}

func (s *Service) ProcessJob(ctx context.Context, payload string) error {
	var p struct {
		MediaID string `json:"media_id"`
		UserID  string `json:"user_id"`
	}
	if err := json.Unmarshal([]byte(payload), &p); err != nil {
		return err
	}
	m, err := s.Media.ByID(ctx, p.MediaID)
	if err != nil {
		return err
	}
	if m == nil {
		return fmt.Errorf("media not found")
	}
	src, err := s.Storage.Abs(m.OriginalPath)
	if err != nil {
		return err
	}

	coverPath := src
	tmpCover := ""
	if m.MediaType == "video" || strings.HasPrefix(m.MimeType, "video/") {
		tmpCover = filepath.Join(os.TempDir(), "ms-cover-"+m.ID+".jpg")
		if err := extractVideoCover(src, tmpCover); err != nil {
			return err
		}
		coverPath = tmpCover
		defer os.Remove(tmpCover)
		relCover := s.Storage.DerivativeRelPath(m.UserID, m.ID, "cover")
		if err := s.saveAsDerivative(ctx, m, "cover", coverPath, relCover); err != nil {
			return err
		}
	}

	imgFile := coverPath
	// HEIC: try sips convert on macOS
	if strings.Contains(strings.ToLower(m.MimeType), "heic") || strings.HasSuffix(strings.ToLower(src), ".heic") {
		tmp := filepath.Join(os.TempDir(), "ms-heic-"+m.ID+".jpg")
		if err := sipsToJPEG(src, tmp); err == nil {
			imgFile = tmp
			defer os.Remove(tmp)
		}
	}

	for _, kind := range []struct {
		name string
		size uint
	}{
		{"thumb_sm", uint(s.Cfg.ThumbSM)},
		{"thumb_md", uint(s.Cfg.ThumbMD)},
	} {
		rel := s.Storage.DerivativeRelPath(m.UserID, m.ID, kind.name)
		abs, err := s.Storage.Abs(rel)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			return err
		}
		w, h, err := writeThumb(imgFile, abs, kind.size)
		if err != nil {
			return err
		}
		fi, _ := os.Stat(abs)
		var sz *int64
		if fi != nil {
			v := fi.Size()
			sz = &v
		}
		ww, hh := int64(w), int64(h)
		if err := s.Derivatives.Upsert(ctx, &repo.Derivative{
			ID: ids.New(), MediaID: m.ID, Kind: kind.name, Path: rel, Width: &ww, Height: &hh, SizeBytes: sz,
		}); err != nil {
			return err
		}
	}
	return s.Media.UpdateStatus(ctx, m.ID, "ready")
}

func (s *Service) saveAsDerivative(ctx context.Context, m *repo.Media, kind, srcPath, rel string) error {
	abs, err := s.Storage.Abs(rel)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return err
	}
	in, err := os.ReadFile(srcPath)
	if err != nil {
		return err
	}
	if err := os.WriteFile(abs, in, 0o644); err != nil {
		return err
	}
	fi, _ := os.Stat(abs)
	var sz *int64
	if fi != nil {
		v := fi.Size()
		sz = &v
	}
	return s.Derivatives.Upsert(ctx, &repo.Derivative{ID: ids.New(), MediaID: m.ID, Kind: kind, Path: rel, SizeBytes: sz})
}

func writeThumb(src, dst string, maxSide uint) (int, int, error) {
	f, err := os.Open(src)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return 0, 0, err
	}
	out := resize.Thumbnail(maxSide, maxSide, img, resize.Lanczos3)
	w := out.Bounds().Dx()
	h := out.Bounds().Dy()
	of, err := os.Create(dst)
	if err != nil {
		return 0, 0, err
	}
	defer of.Close()
	if err := jpeg.Encode(of, out, &jpeg.Options{Quality: 80}); err != nil {
		return 0, 0, err
	}
	return w, h, nil
}

func sipsToJPEG(src, dst string) error {
	cmd := exec.Command("sips", "-s", "format", "jpeg", src, "--out", dst)
	return cmd.Run()
}

func extractVideoCover(src, dst string) error {
	cmd := exec.Command("ffmpeg", "-y", "-ss", "00:00:01", "-i", src, "-frames:v", "1", "-q:v", "2", dst)
	return cmd.Run()
}
