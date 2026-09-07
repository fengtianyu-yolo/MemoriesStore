package device

import (
	"context"
	"database/sql"
	"errors"

	"github.com/fengtianyu/memorystore/server/internal/repo"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/fengtianyu/memorystore/server/pkg/ids"
)

type Service struct {
	Devices *repo.DeviceRepo
}

type RegisterInput struct {
	Name            string `json:"name"`
	Platform        string `json:"platform"`
	ClientDeviceKey string `json:"client_device_key"`
}

func (s *Service) Register(ctx context.Context, userID string, in RegisterInput) (*repo.Device, error) {
	if in.Platform == "" {
		in.Platform = "ios"
	}
	if in.Name == "" {
		in.Name = "iPhone"
	}
	d := &repo.Device{
		ID:              ids.New(),
		UserID:          userID,
		Name:            in.Name,
		Platform:        in.Platform,
		ClientDeviceKey: in.ClientDeviceKey,
	}
	if err := s.Devices.UpsertByClientKey(ctx, d); err != nil {
		return nil, err
	}
	return d, nil
}

func (s *Service) List(ctx context.Context, userID string) ([]repo.Device, error) {
	return s.Devices.ByUser(ctx, userID)
}

func (s *Service) Revoke(ctx context.Context, userID, id string) error {
	if err := s.Devices.Revoke(ctx, userID, id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return apperr.New(apperr.NotFound, "device not found")
		}
		return err
	}
	return nil
}
