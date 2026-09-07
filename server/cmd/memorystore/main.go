package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/fengtianyu/memorystore/server/internal/auth"
	"github.com/fengtianyu/memorystore/server/internal/config"
	"github.com/fengtianyu/memorystore/server/internal/db"
	"github.com/fengtianyu/memorystore/server/internal/derivative"
	"github.com/fengtianyu/memorystore/server/internal/device"
	"github.com/fengtianyu/memorystore/server/internal/httpapi"
	"github.com/fengtianyu/memorystore/server/internal/httpapi/handlers"
	"github.com/fengtianyu/memorystore/server/internal/media"
	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/internal/share"
	"github.com/fengtianyu/memorystore/server/internal/storage"
	"github.com/fengtianyu/memorystore/server/internal/system"
	"github.com/fengtianyu/memorystore/server/internal/upload"
	"github.com/fengtianyu/memorystore/server/internal/worker"
	"github.com/gin-gonic/gin"
)

func main() {
	cfgPath := flag.String("config", "configs/config.example.yaml", "config file path")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		logger.Error("load config", "err", err)
		os.Exit(1)
	}

	eng, err := storage.New(cfg.Data.Root, cfg.Data.MediaRoot)
	if err != nil {
		logger.Error("init storage", "err", err)
		os.Exit(1)
	}

	sqlDB, err := db.Open(eng.DBPath())
	if err != nil {
		logger.Error("open db", "err", err)
		os.Exit(1)
	}
	defer sqlDB.Close()

	users := &repo.UserRepo{DB: sqlDB}
	sessions := &repo.SessionRepo{DB: sqlDB}
	devices := &repo.DeviceRepo{DB: sqlDB}
	invites := &repo.InviteRepo{DB: sqlDB}
	mediaRepo := &repo.MediaRepo{DB: sqlDB}
	derivRepo := &repo.DerivativeRepo{DB: sqlDB}
	uploadRepo := &repo.UploadRepo{DB: sqlDB}
	jobRepo := &repo.JobRepo{DB: sqlDB}
	shareRepo := &repo.ShareRepo{DB: sqlDB}

	authSvc := &auth.Service{Users: users, Sessions: sessions, Invites: invites, Cfg: cfg.Auth}
	deviceSvc := &device.Service{Devices: devices}
	uploadSvc := &upload.Service{
		Uploads: uploadRepo, Media: mediaRepo, Jobs: jobRepo, Storage: eng, UploadCfg: cfg.Upload,
	}
	mediaSvc := &media.Service{Media: mediaRepo, Derivatives: derivRepo, Storage: eng, Jobs: jobRepo}
	shareSvc := &share.Service{Shares: shareRepo, Media: mediaRepo, Cfg: cfg.Share, BaseURL: cfg.Server.PublicBaseURL}
	derivSvc := &derivative.Service{Media: mediaRepo, Derivatives: derivRepo, Storage: eng, Cfg: cfg.Derivative}
	sysSvc := &system.Service{
		DB: sqlDB, Storage: eng, Media: mediaRepo,
		Listen: cfg.Server.Listen, PublicBaseURL: cfg.Server.PublicBaseURL,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := &worker.Worker{Jobs: jobRepo, Deriv: derivSvc, Logger: logger, Conc: cfg.Derivative.WorkerConcurrency}
	w.Start(ctx)

	deps := &handlers.Deps{
		Auth: authSvc, Device: deviceSvc, Upload: uploadSvc, Media: mediaSvc, Share: shareSvc, System: sysSvc,
	}

	gin.SetMode(gin.ReleaseMode)
	r := httpapi.NewRouter(deps)

	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		<-ch
		logger.Info("shutting down")
		cancel()
		os.Exit(0)
	}()

	logger.Info("MemoryStore server listening",
		"addr", cfg.Server.Listen,
		"data", eng.Root,
		"media", eng.MediaRoot,
	)
	if err := r.Run(cfg.Server.Listen); err != nil {
		logger.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
