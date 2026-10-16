package catalog

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// ErrNotFound reports that no catalog has been stored.
var ErrNotFound = errors.New("catalog: not stored")

// Record is the persisted form: the verified envelope plus the environment
// whose keys verified it, so the next Bridge process re-verifies with the
// same keys before trusting the file.
type Record struct {
	Environment string          `json:"environment"`
	KID         string          `json:"kid"`
	Signature   string          `json:"signature"`
	Catalog     json.RawMessage `json:"catalog"`
}

// Signed returns the envelope inside the record.
func (r Record) Signed() Signed {
	return Signed{Catalog: r.Catalog, KID: r.KID, Signature: r.Signature}
}

// Store keeps the last applied catalog envelope on disk (0600 inside a 0700
// directory). The file is never trusted on its own: Load returns the raw
// record and the caller verifies it again.
type Store struct {
	path string
}

// DefaultPath is the catalog file next to the other Bridge state files.
func DefaultPath(homeDir string) string {
	return filepath.Join(homeDir, "Library", "Application Support", "cn.qkfintech.zhiban", "local-coding-tools", "state", "catalog.json")
}

// NewStore returns a store at path; an empty path disables persistence.
func NewStore(path string) *Store {
	path = filepath.Clean(path)
	if path == "." || !filepath.IsAbs(path) {
		return nil
	}
	return &Store{path: path}
}

// Path returns the file path.
func (s *Store) Path() string {
	if s == nil {
		return ""
	}
	return s.path
}

// Load reads the stored record; ErrNotFound when nothing is stored.
func (s *Store) Load() (Record, error) {
	if s == nil {
		return Record{}, ErrNotFound
	}
	content, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Record{}, ErrNotFound
		}
		return Record{}, err
	}
	if len(content) > maxCatalogBytes+4096 {
		return Record{}, ErrTooLarge
	}
	var record Record
	if err := json.Unmarshal(content, &record); err != nil {
		return Record{}, errors.Join(ErrInvalid, err)
	}
	return record, nil
}

// Save writes the record atomically (temporary file + rename).
func (s *Store) Save(record Record) error {
	if s == nil {
		return nil
	}
	if !ValidEnvironment(record.Environment) || len(bytes.TrimSpace(record.Catalog)) == 0 {
		return ErrInvalid
	}
	content, err := json.Marshal(record)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(s.path), ".catalog-*.tmp")
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(temporary.Name())
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(content); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary.Name(), s.path); err != nil {
		return err
	}
	committed = true
	return nil
}

// Clear removes the stored record; a missing file is not an error.
func (s *Store) Clear() error {
	if s == nil {
		return nil
	}
	if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
