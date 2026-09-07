package storage

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Engine manages filesystem layout.
// Root: SQLite / logs（元数据）
// MediaRoot: originals / derivatives / upload tmp（照片与视频，可挂外接盘）
type Engine struct {
	Root      string
	MediaRoot string
}

func New(root, mediaRoot string) (*Engine, error) {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(mediaRoot) == "" {
		mediaRoot = root
	}
	absMedia, err := filepath.Abs(mediaRoot)
	if err != nil {
		return nil, err
	}
	e := &Engine{Root: absRoot, MediaRoot: absMedia}

	for _, d := range []string{
		filepath.Join(absRoot, "db"),
		filepath.Join(absRoot, "logs"),
		filepath.Join(absMedia, "originals"),
		filepath.Join(absMedia, "derivatives"),
		filepath.Join(absMedia, "tmp", "uploads"),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	return e, nil
}

func (e *Engine) DBPath() string {
	return filepath.Join(e.Root, "db", "memorystore.db")
}

func (e *Engine) UploadTmpDir(userID, uploadID string) string {
	return filepath.Join(e.MediaRoot, "tmp", "uploads", userID, uploadID)
}

func (e *Engine) EnsureUploadTmp(userID, uploadID string) (string, error) {
	dir := e.UploadTmpDir(userID, uploadID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

func (e *Engine) UploadDataPath(userID, uploadID string) string {
	return filepath.Join(e.UploadTmpDir(userID, uploadID), "data.bin")
}

// OriginalRelPath builds originals/{userId}/yyyy/mm/dd/{mediaId}_{hash12}{ext}
func (e *Engine) OriginalRelPath(userID, mediaID, hash, ext string, takenAt time.Time) string {
	if takenAt.IsZero() {
		takenAt = time.Now().UTC()
	}
	if ext != "" && !strings.HasPrefix(ext, ".") {
		ext = "." + ext
	}
	short := hash
	if len(short) > 12 {
		short = short[:12]
	}
	return filepath.ToSlash(filepath.Join(
		"originals", userID,
		takenAt.Format("2006"), takenAt.Format("01"), takenAt.Format("02"),
		fmt.Sprintf("%s_%s%s", mediaID, short, ext),
	))
}

func (e *Engine) DerivativeRelPath(userID, mediaID, kind string) string {
	return filepath.ToSlash(filepath.Join("derivatives", userID, kind, mediaID+".jpg"))
}

// Abs resolves a media-relative path under MediaRoot.
func (e *Engine) Abs(rel string) (string, error) {
	clean := filepath.Clean(filepath.Join(e.MediaRoot, filepath.FromSlash(rel)))
	root := e.MediaRoot
	if !strings.HasPrefix(clean, root+string(os.PathSeparator)) && clean != root {
		return "", fmt.Errorf("path escapes media root")
	}
	return clean, nil
}

// CommitUpload atomically moves tmp data.bin to original path.
func (e *Engine) CommitUpload(userID, uploadID, relOriginal string) error {
	src := e.UploadDataPath(userID, uploadID)
	dst, err := e.Abs(relOriginal)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err != nil {
		// cross-device fallback（tmp 与 originals 不在同一卷时）
		if err2 := copyFile(src, dst); err2 != nil {
			return err2
		}
		_ = os.Remove(src)
	}
	_ = os.RemoveAll(e.UploadTmpDir(userID, uploadID))
	return nil
}

func (e *Engine) RemoveUploadTmp(userID, uploadID string) error {
	return os.RemoveAll(e.UploadTmpDir(userID, uploadID))
}

func (e *Engine) Writable() error {
	if err := writeProbe(e.Root); err != nil {
		return fmt.Errorf("data root: %w", err)
	}
	if err := writeProbe(e.MediaRoot); err != nil {
		return fmt.Errorf("media root: %w", err)
	}
	return nil
}

func writeProbe(dir string) error {
	f, err := os.CreateTemp(dir, ".writetest-*")
	if err != nil {
		return err
	}
	name := f.Name()
	_ = f.Close()
	return os.Remove(name)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}

// ExtFromMIME maps common mime types to extensions.
func ExtFromMIME(mime string) string {
	switch strings.ToLower(mime) {
	case "image/jpeg", "image/jpg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/heic", "image/heif":
		return ".heic"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	case "video/mp4":
		return ".mp4"
	case "video/quicktime":
		return ".mov"
	default:
		return ".bin"
	}
}
