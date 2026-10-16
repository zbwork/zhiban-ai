// community-bootstrap reads initial administrator credentials from stdin JSON.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/crypto"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/pgcli"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/communitybootstrap"
	"io"
	"net/mail"
	"os"
	"strings"
	"time"
)

type input struct{ Email, Name, Password string }

func readInput(r io.Reader) (input, error) {
	var in input
	d := json.NewDecoder(io.LimitReader(r, 16385))
	d.DisallowUnknownFields()
	if err := d.Decode(&in); err != nil {
		return in, errors.New("invalid bootstrap JSON")
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return in, errors.New("expected one JSON object")
	}
	in.Email = strings.TrimSpace(in.Email)
	in.Name = strings.TrimSpace(in.Name)
	address, err := mail.ParseAddress(in.Email)
	if err != nil || address.Address != in.Email || len(in.Email) > 254 || len(in.Name) == 0 || len(in.Name) > 100 || len(in.Password) < 12 || len(in.Password) > 1024 {
		return in, errors.New("valid email, name and 12-1024 byte password required")
	}
	return in, nil
}
func run(ctx context.Context, r io.Reader) error {
	dsn := os.Getenv("AGBUS_POSTGRES_DSN")
	if dsn == "" {
		return errors.New("AGBUS_POSTGRES_DSN required")
	}
	in, err := readInput(r)
	if err != nil {
		return err
	}
	hash, err := crypto.HashPassword(in.Password)
	if err != nil {
		return errors.New("password hashing failed")
	}
	pool, err := pgcli.New(ctx, dsn, 2, 0)
	if err != nil {
		return errors.New("database connection failed")
	}
	defer pool.Close()
	_, err = repo.New(pool).Create(ctx, in.Email, in.Name, hash)
	if errors.Is(err, repo.ErrAlreadyInitialized) {
		return err
	}
	if err != nil {
		return errors.New("bootstrap transaction failed; verify empty platform and migration prerequisites")
	}
	return nil
}
func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := run(ctx, os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Community platform administrator initialized")
}
