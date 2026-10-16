//go:build windows

package codexsessions

// Windows ships no sqlite3.exe, but Windows 10 / 11 carry the engine itself
// as %SystemRoot%\System32\winsqlite3.dll (used by system components; the
// test machine had it, 2026-09-18). The five entry points below are all the
// UPDATE needs, called without cgo. The DLL is loaded by absolute path so a
// same-named file next to the Bridge can never be picked up instead.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"unsafe"
)

const (
	sqliteOK            = 0
	sqliteOpenReadWrite = 0x00000002
	sqliteOpenCreate    = 0x00000004
)

type winSQLite struct {
	openV2      *syscall.Proc
	busyTimeout *syscall.Proc
	exec        *syscall.Proc
	changes     *syscall.Proc
	errMsg      *syscall.Proc
	free        *syscall.Proc
	closeV2     *syscall.Proc
}

var (
	loadOnce sync.Once
	engine   *winSQLite
	loadErr  error
)

func loadEngine() (*winSQLite, error) {
	loadOnce.Do(func() {
		root := os.Getenv("SystemRoot")
		if root == "" {
			root = `C:\Windows`
		}
		dll, err := syscall.LoadDLL(filepath.Join(root, "System32", "winsqlite3.dll"))
		if err != nil {
			loadErr = err
			return
		}
		lookup := func(name string) *syscall.Proc {
			if loadErr != nil {
				return nil
			}
			proc, err := dll.FindProc(name)
			if err != nil {
				loadErr = err
			}
			return proc
		}
		engine = &winSQLite{
			openV2:      lookup("sqlite3_open_v2"),
			busyTimeout: lookup("sqlite3_busy_timeout"),
			exec:        lookup("sqlite3_exec"),
			changes:     lookup("sqlite3_changes"),
			errMsg:      lookup("sqlite3_errmsg"),
			free:        lookup("sqlite3_free"),
			closeV2:     lookup("sqlite3_close_v2"),
		}
		if loadErr != nil {
			engine = nil
		}
	})
	return engine, loadErr
}

// indexEngineAvailable reports whether winsqlite3.dll loaded.
func indexEngineAvailable() bool {
	_, err := loadEngine()
	return err == nil
}

// updateIndex runs statement on database through winsqlite3.dll and
// returns the number of rows it changed.
func updateIndex(_ context.Context, database, statement string) (int, error) {
	return runSQL(database, statement, sqliteOpenReadWrite)
}

// runSQL opens database with flags, runs statement and returns the number
// of rows the last statement changed.
func runSQL(database, statement string, flags uintptr) (int, error) {
	sqlite, err := loadEngine()
	if err != nil {
		return 0, err
	}
	name := append([]byte(database), 0)
	var db uintptr
	code, _, _ := sqlite.openV2.Call(uintptr(unsafe.Pointer(&name[0])), uintptr(unsafe.Pointer(&db)), flags, 0)
	if code != sqliteOK {
		if db != 0 {
			_, _, _ = sqlite.closeV2.Call(db)
		}
		return 0, fmt.Errorf("sqlite3_open_v2: code %d", code)
	}
	defer sqlite.closeV2.Call(db)
	_, _, _ = sqlite.busyTimeout.Call(db, sqliteBusyMillis)

	sql := append([]byte(statement), 0)
	var message uintptr
	code, _, _ = sqlite.exec.Call(db, uintptr(unsafe.Pointer(&sql[0])), 0, 0, uintptr(unsafe.Pointer(&message)))
	if code != sqliteOK {
		detail := ""
		if message != 0 {
			detail = cString(message)
			_, _, _ = sqlite.free.Call(message)
		} else if text, _, _ := sqlite.errMsg.Call(db); text != 0 {
			detail = cString(text)
		}
		return 0, errors.New(fmt.Sprintf("sqlite3_exec: code %d: %s", code, detail))
	}
	changed, _, _ := sqlite.changes.Call(db)
	return int(changed), nil
}

// cString copies a NUL-terminated C string that SQLite owns (memory the Go
// collector never moves, so the pointer is used as is).
func cString(p uintptr) string {
	if p == 0 {
		return ""
	}
	// Re-read the address through a pointer variable: this is C memory, not
	// something the Go collector tracks, and vet's uintptr rule does not
	// apply to it.
	base := *(*unsafe.Pointer)(unsafe.Pointer(&p))
	var out []byte
	for offset := 0; ; offset++ {
		b := *(*byte)(unsafe.Add(base, offset))
		if b == 0 {
			return string(out)
		}
		out = append(out, b)
	}
}
