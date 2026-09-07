package worker

import (
	"context"
	"log/slog"
	"time"

	"github.com/fengtianyu/memorystore/server/internal/derivative"
	"github.com/fengtianyu/memorystore/server/internal/repo"
)

type Worker struct {
	Jobs   *repo.JobRepo
	Deriv  *derivative.Service
	Logger *slog.Logger
	Conc   int
}

func (w *Worker) Start(ctx context.Context) {
	n := w.Conc
	if n < 1 {
		n = 1
	}
	for i := 0; i < n; i++ {
		go w.loop(ctx)
	}
}

func (w *Worker) loop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		job, err := w.Jobs.ClaimNext(ctx)
		if err != nil {
			w.Logger.Error("claim job", "err", err)
			time.Sleep(time.Second)
			continue
		}
		if job == nil {
			time.Sleep(2 * time.Second)
			continue
		}
		w.Logger.Info("job start", "id", job.ID, "type", job.Type, "attempt", job.Attempts)
		var runErr error
		switch job.Type {
		case "generate_derivatives":
			runErr = w.Deriv.ProcessJob(ctx, job.Payload)
		default:
			runErr = nil
			_ = w.Jobs.Done(ctx, job.ID)
			continue
		}
		if runErr != nil {
			w.Logger.Error("job fail", "id", job.ID, "err", runErr)
			final := job.Attempts >= 5
			backoff := time.Now().UTC().Add(time.Duration(job.Attempts*job.Attempts) * time.Minute)
			_ = w.Jobs.Fail(ctx, job.ID, runErr.Error(), backoff, final)
			continue
		}
		_ = w.Jobs.Done(ctx, job.ID)
		w.Logger.Info("job done", "id", job.ID)
	}
}
