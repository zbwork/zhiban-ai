//go:build darwin && cgo

package launch

/*
#cgo LDFLAGS: -framework Foundation
#include <stddef.h>
#include <stdlib.h>

int zb_resolve_bookmark(const void *bytes, size_t length, char **path, int *stale);
int zb_create_bookmark(const char *path, void **bytes, size_t *length);
void zb_release_buffer(void *buffer);
*/
import "C"

import (
	"context"
	"errors"
	"unsafe"
)

func NewMacOSBookmarkResolver() ResolveBookmarkFunc {
	return func(ctx context.Context, bookmark []byte) (BookmarkResolution, error) {
		select {
		case <-ctx.Done():
			return BookmarkResolution{}, ctx.Err()
		default:
		}
		if len(bookmark) == 0 || len(bookmark) > maxBookmarkBytes {
			return BookmarkResolution{}, ErrProjectPermissionDenied
		}
		var path *C.char
		var stale C.int
		result := C.zb_resolve_bookmark(unsafe.Pointer(&bookmark[0]), C.size_t(len(bookmark)), &path, &stale)
		if path != nil {
			defer C.zb_release_buffer(unsafe.Pointer(path))
		}
		if result != 0 || path == nil {
			return BookmarkResolution{}, ErrProjectPermissionDenied
		}
		return BookmarkResolution{Path: C.GoString(path), Stale: stale != 0}, nil
	}
}

func createBookmarkForTest(path string) ([]byte, error) {
	value := C.CString(path)
	defer C.free(unsafe.Pointer(value))
	var output unsafe.Pointer
	var length C.size_t
	if C.zb_create_bookmark(value, &output, &length) != 0 || output == nil || length == 0 {
		return nil, errors.New("create test bookmark")
	}
	defer C.zb_release_buffer(output)
	return C.GoBytes(output, C.int(length)), nil
}
