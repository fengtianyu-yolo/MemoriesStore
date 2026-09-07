package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Server     ServerConfig     `yaml:"server"`
	Data       DataConfig       `yaml:"data"`
	Auth       AuthConfig       `yaml:"auth"`
	SMS        SMSConfig        `yaml:"sms"`
	Upload     UploadConfig     `yaml:"upload"`
	Derivative DerivativeConfig `yaml:"derivative"`
	Share      ShareConfig      `yaml:"share"`
}

type ServerConfig struct {
	Listen        string `yaml:"listen"`
	PublicBaseURL string `yaml:"public_base_url"`
}

type DataConfig struct {
	// Root 存放 SQLite、日志等元数据（建议本机 SSD）
	Root string `yaml:"root"`
	// MediaRoot 存放原片、派生图、上传临时文件（可指向外接硬盘）。
	// 为空时与 Root 相同，保持兼容。
	MediaRoot string `yaml:"media_root"`
}

type AuthConfig struct {
	RegisterMode        string `yaml:"register_mode"` // open | invite | closed
	AccessTokenTTLHrs   int    `yaml:"access_token_ttl_hours"`
	RefreshTokenTTLDays int    `yaml:"refresh_token_ttl_days"`
	PasswordMinLength   int    `yaml:"password_min_length"`
	AdminToken          string `yaml:"admin_token"`
}

type SMSConfig struct {
	Enabled bool `yaml:"enabled"`
}

type UploadConfig struct {
	MaxBytes        int64 `yaml:"max_bytes"`
	ChunkSizeHint   int64 `yaml:"chunk_size_hint"`
	SessionTTLHours int   `yaml:"session_ttl_hours"`
}

type DerivativeConfig struct {
	ThumbSM           int `yaml:"thumb_sm"`
	ThumbMD           int `yaml:"thumb_md"`
	WorkerConcurrency int `yaml:"worker_concurrency"`
}

type ShareConfig struct {
	DefaultTTLDays int `yaml:"default_ttl_days"`
}

func Default() Config {
	return Config{
		Server: ServerConfig{
			Listen:        "127.0.0.1:8080",
			PublicBaseURL: "http://127.0.0.1:8080",
		},
		Data: DataConfig{Root: "./data"},
		Auth: AuthConfig{
			RegisterMode:        "open",
			AccessTokenTTLHrs:   168,
			RefreshTokenTTLDays: 30,
			PasswordMinLength:   8,
		},
		Upload: UploadConfig{
			MaxBytes:        5 << 30,
			ChunkSizeHint:   8 << 20,
			SessionTTLHours: 24,
		},
		Derivative: DerivativeConfig{
			ThumbSM:           320,
			ThumbMD:           1280,
			WorkerConcurrency: 2,
		},
		Share: ShareConfig{DefaultTTLDays: 7},
	}
}

func Load(path string) (Config, error) {
	cfg := Default()
	if path == "" {
		applyEnvOverrides(&cfg)
		normalizeDataPaths(&cfg)
		return cfg, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read config: %w", err)
	}
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}
	applyEnvOverrides(&cfg)
	normalizeDataPaths(&cfg)
	if cfg.Auth.PasswordMinLength < 6 {
		cfg.Auth.PasswordMinLength = 6
	}
	if cfg.Derivative.WorkerConcurrency < 1 {
		cfg.Derivative.WorkerConcurrency = 1
	}
	return cfg, nil
}

// 环境变量优先，便于部署时挂载外接盘而不改配置文件。
func applyEnvOverrides(cfg *Config) {
	if v := strings.TrimSpace(os.Getenv("MEMORYSTORE_DATA_ROOT")); v != "" {
		cfg.Data.Root = v
	}
	if v := strings.TrimSpace(os.Getenv("MEMORYSTORE_MEDIA_ROOT")); v != "" {
		cfg.Data.MediaRoot = v
	}
}

func normalizeDataPaths(cfg *Config) {
	if strings.TrimSpace(cfg.Data.Root) == "" {
		cfg.Data.Root = "./data"
	}
	if strings.TrimSpace(cfg.Data.MediaRoot) == "" {
		cfg.Data.MediaRoot = cfg.Data.Root
	}
}

func (c AuthConfig) AccessTTL() time.Duration {
	return time.Duration(c.AccessTokenTTLHrs) * time.Hour
}

func (c AuthConfig) RefreshTTL() time.Duration {
	return time.Duration(c.RefreshTokenTTLDays) * 24 * time.Hour
}

func (c UploadConfig) SessionTTL() time.Duration {
	return time.Duration(c.SessionTTLHours) * time.Hour
}
