//go:build windows

package credential

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

// Windows credential backend: each secure item is stored as a DPAPI
// (CryptProtectData, CurrentUser scope) ciphertext file under the user's
// LOCALAPPDATA. DPAPI binds the ciphertext to the logged-in Windows account,
// so a copied file is useless to any other user or machine — the same
// per-user protection the macOS Keychain backend provides. A fixed entropy
// blob additionally binds decryption to this application's code.
//
// This is the Windows counterpart of macOSKeychainBackend; the shared
// keychainStore wraps it into a credential.Store.

var (
	dpapiCrypt32           = syscall.NewLazyDLL("crypt32.dll")
	dpapiKernel32          = syscall.NewLazyDLL("kernel32.dll")
	procCryptProtectData   = dpapiCrypt32.NewProc("CryptProtectData")
	procCryptUnprotectData = dpapiCrypt32.NewProc("CryptUnprotectData")
	procLocalFree          = dpapiKernel32.NewProc("LocalFree")
)

// cryptProtectUIForbidden forbids any interactive prompt: the Bridge runs
// non-interactively and must never block on a DPAPI dialog.
const cryptProtectUIForbidden = 0x1

// dpapiEntropy is a fixed application salt mixed into every protect/unprotect
// call. It is not a secret (it ships in the binary); it only ensures a blob
// protected by this app cannot be trivially unprotected by unrelated code.
var dpapiEntropy = []byte("cn.qkfintech.zhiban/local-coding-tools/dpapi-v1")

type dataBlob struct {
	cbData uint32
	pbData *byte
}

func newBlob(data []byte) dataBlob {
	if len(data) == 0 {
		return dataBlob{}
	}
	return dataBlob{cbData: uint32(len(data)), pbData: &data[0]}
}

func (b dataBlob) bytes() []byte {
	if b.pbData == nil || b.cbData == 0 {
		return nil
	}
	out := make([]byte, b.cbData)
	copy(out, unsafe.Slice(b.pbData, b.cbData))
	return out
}

// NewSystemCredentialStore returns the DPAPI-backed store on Windows.
func NewSystemCredentialStore() Store {
	return newKeychainStore(windowsDPAPIBackend{})
}

type windowsDPAPIBackend struct{}

func credentialDir() (string, error) {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, "AppData", "Local")
		}
	}
	if base == "" {
		return "", ErrKeychainUnavailable
	}
	dir := filepath.Join(base, "cn.qkfintech.zhiban", "local-coding-tools", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

func credentialPath(account string) (string, error) {
	if account == "" {
		return "", ErrInvalidData
	}
	// Account names are fixed internal constants (device-identity-v1 /
	// device-authorization-v1); reject anything that could escape the dir.
	if account != keychainIdentityAccount && account != keychainAuthorizationAccount {
		return "", ErrInvalidData
	}
	dir, err := credentialDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, account+".dpapi"), nil
}

func (windowsDPAPIBackend) Load(ctx context.Context, account string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	path, err := credentialPath(account)
	if err != nil {
		return nil, err
	}
	ciphertext, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if len(ciphertext) == 0 || len(ciphertext) > 4*maxKeychainItemBytes {
		return nil, ErrInvalidData
	}
	plaintext, err := dpapiUnprotect(ciphertext)
	if err != nil {
		return nil, err
	}
	if len(plaintext) == 0 || len(plaintext) > maxKeychainItemBytes {
		zeroBytes(plaintext)
		return nil, ErrInvalidData
	}
	return plaintext, nil
}

func (windowsDPAPIBackend) Save(ctx context.Context, account string, value []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(value) == 0 || len(value) > maxKeychainItemBytes {
		return ErrInvalidData
	}
	path, err := credentialPath(account)
	if err != nil {
		return err
	}
	ciphertext, err := dpapiProtect(value)
	if err != nil {
		return err
	}
	// Atomic replace: write a sibling temp file then rename over the target.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, ciphertext, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func (windowsDPAPIBackend) Delete(ctx context.Context, account string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, err := credentialPath(account)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrNotFound
		}
		return err
	}
	return nil
}

func dpapiProtect(plaintext []byte) ([]byte, error) {
	in := newBlob(plaintext)
	entropy := newBlob(dpapiEntropy)
	var out dataBlob
	r1, _, callErr := procCryptProtectData.Call(
		uintptr(unsafe.Pointer(&in)),
		0,
		uintptr(unsafe.Pointer(&entropy)),
		0,
		0,
		uintptr(cryptProtectUIForbidden),
		uintptr(unsafe.Pointer(&out)),
	)
	if r1 == 0 {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return nil, callErr
		}
		return nil, ErrKeychainUnavailable
	}
	defer localFree(out.pbData)
	result := out.bytes()
	if len(result) == 0 {
		return nil, ErrKeychainUnavailable
	}
	return result, nil
}

func dpapiUnprotect(ciphertext []byte) ([]byte, error) {
	in := newBlob(ciphertext)
	entropy := newBlob(dpapiEntropy)
	var out dataBlob
	r1, _, callErr := procCryptUnprotectData.Call(
		uintptr(unsafe.Pointer(&in)),
		0,
		uintptr(unsafe.Pointer(&entropy)),
		0,
		0,
		uintptr(cryptProtectUIForbidden),
		uintptr(unsafe.Pointer(&out)),
	)
	if r1 == 0 {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return nil, callErr
		}
		return nil, ErrInvalidData
	}
	defer localFree(out.pbData)
	return out.bytes(), nil
}

func localFree(p *byte) {
	if p != nil {
		_, _, _ = procLocalFree.Call(uintptr(unsafe.Pointer(p)))
	}
}
