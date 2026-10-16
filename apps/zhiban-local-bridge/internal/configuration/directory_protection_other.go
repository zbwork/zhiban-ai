//go:build !darwin || !cgo

package configuration

import "os"

// The private-ancestor exception is currently proven only with macOS ACLs.
func directoryProtection(*os.File) (trusted, private bool) { return false, false }
