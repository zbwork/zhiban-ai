// community-migrate applies only the embedded community migration set.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/communitymigrate"
)

func main() {
	dsn := os.Getenv("AGBUS_POSTGRES_DSN")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "AGBUS_POSTGRES_DSN required")
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "invalid database configuration")
		os.Exit(1)
	}
	defer pool.Close()
	if err = communitymigrate.Apply(ctx, pool); err != nil {
		// Do not print driver errors, which can contain connection or SQL data.
		fmt.Fprintln(os.Stderr, "community migration failed; verify empty schema, connectivity and migration checksums")
		os.Exit(1)
	}
	fmt.Println("Community migrations applied")
}
