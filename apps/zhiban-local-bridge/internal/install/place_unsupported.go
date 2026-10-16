//go:build !darwin

package install

import "os"

// validateSystemApplicationsDirectory: only macOS ships a group-writable system
// applications folder that is nevertheless safe to place into. Elsewhere no
// such exception exists and the ordinary directory rule applies.
func validateSystemApplicationsDirectory(directory *os.File) error {
	return validateDirectory(directory)
}
