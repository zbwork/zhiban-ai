package drive

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5/pgxpool"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/knowledge"
	"log"
	"strings"
	"time"
)

// RunKnowledgeCleanup retries deletes from durable KB/document tombstones.
func RunKnowledgeCleanup(ctx context.Context, pool *pgxpool.Pool, storage *Storage) {
	r := repo.New(pool)
	timer := time.NewTicker(time.Minute)
	defer timer.Stop()
	for {
		round, stopRound := context.WithTimeout(ctx, 45*time.Second)
		runKnowledgeCleanupRound(round, r, storage)
		stopRound()
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
	}
}

type knowledgeCleanupRepo interface {
	DeletedOriginals(context.Context, int) ([]repo.DeletedOriginal, error)
	FinishOriginalCleanup(context.Context, int64, string, bool) error
}

func runKnowledgeCleanupRound(round context.Context, r knowledgeCleanupRepo, storage *Storage) {
	for batch := 0; batch < 10 && round.Err() == nil; batch++ {
		rows, err := r.DeletedOriginals(round, 100)
		if err != nil {
			log.Printf("knowledge cleanup lookup failed: %v", err)
			break
		}
		if len(rows) == 0 {
			break
		}
		for _, d := range rows {
			if round.Err() != nil {
				break
			}
			item, cancel := context.WithTimeout(round, 15*time.Second)
			valid := strings.HasPrefix(d.Key, fmt.Sprintf("tenants/%d/knowledge/", d.TenantID)) && !strings.Contains(d.Key, "..")
			success := false
			if valid {
				store, err := storage.Resolve(item, d.TenantID)
				if err == nil {
					err = store.Delete(item, d.Key)
				}
				success = err == nil
			}
			cancel()
			if err := r.FinishOriginalCleanup(round, d.ID, d.Key, success); err != nil {
				log.Printf("knowledge cleanup state failed: document=%d error=%v", d.ID, err)
			}
			if !success {
				log.Printf("knowledge cleanup deferred: document=%d", d.ID)
			}
		}
		if len(rows) < 100 {
			break
		}
	}
}
