//go:build !darwin && !windows

package netproxy

import (
	"context"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

type unsupportedPlatform struct{}

func newPlatform(string, *shellenv.LoginShellLookup) platform { return unsupportedPlatform{} }

func (unsupportedPlatform) supported() bool                         { return false }
func (unsupportedPlatform) systemProxy(context.Context) SystemProxy { return SystemProxy{} }
func (unsupportedPlatform) coverage(context.Context, []string) map[string]bool {
	return map[string]bool{}
}
func (unsupportedPlatform) apply(context.Context, []string) error { return nil }
func (unsupportedPlatform) noProxy(context.Context) string        { return "" }
