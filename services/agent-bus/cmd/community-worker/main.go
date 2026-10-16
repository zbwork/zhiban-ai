// community-worker runs shared drive maintenance without commercial tasks.
package main

import (
	"context"
	"errors"
	"flag"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	communitydrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/pgcli"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
	wkoutboxrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/wukongoutbox"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drivescheduler"
	wkoutboxsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/wukongoutbox"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

func run(ctx context.Context, path string) error {
	cfg, err := config.Load(path)
	if err != nil {
		return err
	}
	storage, err := communitydrive.NewStorage(cfg)
	if err != nil {
		return err
	}
	if storage == nil {
		return errors.New("community worker requires object storage")
	}
	startup, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	pool, err := pgcli.New(startup, cfg.PostgresDSN, 10, 0)
	if err != nil {
		return errors.New("PostgreSQL unavailable")
	}
	defer pool.Close()
	jobs := repo.NewWorkerJobRepo(pool)
	worker := svc.NewWorkerSvc(pool, repo.NewTicketRepo(pool), repo.NewRecycleRepo(pool), repo.NewFileRepo(pool), repo.NewFolderRepo(pool), repo.NewFileVersionRepo(pool), repo.NewSpaceRepo(pool), repo.NewQuotaRepo(pool), storage, jobs)
	logger := logpkg.New("json", "info", "", "")
	fns := map[string]func(context.Context) (svc.WorkerRunStats, error){"staging_reaper": worker.RunStagingReaperWithStats, "recycle_cleaner": worker.RunRecycleCleanerWithStats, "version_cleaner": worker.RunVersionCleanerWithStats}
	locks := make(map[string]*sync.Mutex, len(fns))
	for name := range fns {
		locks[name] = &sync.Mutex{}
	}
	var wg sync.WaitGroup
	if cfg.WuKong.URL != "" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			wkoutboxsvc.Run(ctx, wkoutboxrepo.New(pool), wukong.NewClient(cfg.WuKong.URL, nil), wkoutboxsvc.WorkerOptions{})
		}()
	}
	wg.Add(len(fns) + 1)
	for name, fn := range fns {
		go drivescheduler.RunJob(ctx, &wg, logger, worker, jobs, name, svc.WorkerJobIntervals[name], locks[name], fn)
	}
	go drivescheduler.RunTriggerPoller(ctx, &wg, logger, worker, jobs, fns, locks)
	wg.Wait()
	return nil
}
func main() {
	path := flag.String("config", "configs/community/bus.yaml", "community configuration")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, *path); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
