//go:build !darwin && !windows

package install

import (
	"context"
	"syscall"
)

func defaultBundleTools() BundleTools {
	return BundleTools{
		ExtractZip:   func(context.Context, string, string) error { return syscall.ENOTSUP },
		ExtractDMG:   func(context.Context, string, string, []string) error { return syscall.ENOTSUP },
		VerifyBundle: func(context.Context, string, string) error { return syscall.ENOTSUP },
		AssessBundle: func(context.Context, string) error { return syscall.ENOTSUP },
		BundleInUse:  func(string) (bool, error) { return false, syscall.ENOTSUP },
	}
}
