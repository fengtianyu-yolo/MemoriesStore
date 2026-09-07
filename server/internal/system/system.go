package system

import (
	"context"
	"database/sql"

	"github.com/fengtianyu/memorystore/server/internal/db"
	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/internal/storage"
	"golang.org/x/sys/unix"
)

type Service struct {
	DB            *sql.DB
	Storage       *storage.Engine
	Media         *repo.MediaRepo
	Listen        string
	PublicBaseURL string
}

type Health struct {
	OK    bool              `json:"ok"`
	Parts map[string]string `json:"parts"`
}

func (s *Service) Health(ctx context.Context) Health {
	h := Health{OK: true, Parts: map[string]string{}}
	if err := db.Ping(s.DB); err != nil {
		h.OK = false
		h.Parts["db"] = err.Error()
	} else {
		h.Parts["db"] = "ok"
	}
	if err := s.Storage.Writable(); err != nil {
		h.OK = false
		h.Parts["storage"] = err.Error()
	} else {
		h.Parts["storage"] = "ok"
	}
	return h
}

type StorageInfo struct {
	DataRoot          string `json:"data_root"`
	MediaRoot         string `json:"media_root"`
	TotalBytes        uint64 `json:"total_bytes"`
	AvailableBytes    uint64 `json:"available_bytes"`
	MyOriginalsBytes  int64  `json:"my_originals_bytes"`
	MyMediaCount      int64  `json:"my_media_count"`
}

func (s *Service) StorageInfo(ctx context.Context, userID string) (*StorageInfo, error) {
	var st unix.Statfs_t
	// 按媒体盘统计可用空间（外接硬盘场景）
	if err := unix.Statfs(s.Storage.MediaRoot, &st); err != nil {
		return nil, err
	}
	sum, cnt, err := s.Media.SumSizeByUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	return &StorageInfo{
		DataRoot:         s.Storage.Root,
		MediaRoot:        s.Storage.MediaRoot,
		TotalBytes:       st.Blocks * uint64(st.Bsize),
		AvailableBytes:   st.Bavail * uint64(st.Bsize),
		MyOriginalsBytes: sum,
		MyMediaCount:     cnt,
	}, nil
}
