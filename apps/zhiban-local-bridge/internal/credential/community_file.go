package credential

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// Plaintext persistence explicitly selected for community BYOK only.
type communityFileBackend struct{ root string }

func (s *communityFileBackend) path(account string) (string, error) {
	if account != "community-byok-"+TargetCodexCLI+"-v1" && account != "community-byok-"+TargetClaudeCLI+"-v1" {
		return "", ErrInvalidData
	}
	info, err := os.Lstat(s.root)
	if err == nil && (!info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
		return "", ErrInvalidData
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.MkdirAll(s.root, 0700); err != nil {
		return "", err
	}
	if err := os.Chmod(s.root, 0700); err != nil {
		return "", err
	}
	return filepath.Join(s.root, account+".json"), nil
}
func (s *communityFileBackend) Load(ctx context.Context, account string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	path, err := s.path(account)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxKeychainItemBytes {
		return nil, ErrInvalidData
	}
	if err := os.Chmod(path, 0600); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maxKeychainItemBytes+1))
	if len(raw) > maxKeychainItemBytes {
		return nil, ErrInvalidData
	}
	return raw, err
}
func (s *communityFileBackend) Save(ctx context.Context, account string, raw []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(raw) > maxKeychainItemBytes {
		return ErrInvalidData
	}
	path, err := s.path(account)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(s.root, ".byok-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err := file.Chmod(0600); err != nil {
		return err
	}
	if _, err := file.Write(raw); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
func (s *communityFileBackend) Delete(ctx context.Context, account string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, err := s.path(account)
	if err != nil {
		return err
	}
	err = os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	}
	return err
}
