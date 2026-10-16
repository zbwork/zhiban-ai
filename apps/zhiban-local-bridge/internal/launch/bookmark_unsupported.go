//go:build !darwin || !cgo

package launch

import "context"

func NewMacOSBookmarkResolver() ResolveBookmarkFunc {
	return func(context.Context, []byte) (BookmarkResolution, error) {
		return BookmarkResolution{}, ErrProjectPermissionDenied
	}
}
