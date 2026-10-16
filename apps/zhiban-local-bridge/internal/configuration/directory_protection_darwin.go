//go:build darwin && cgo

package configuration

/*
#include <errno.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>

// A deny-only ACL cannot add traversal or mutation rights. Any allow entry,
// unknown tag, or failed inspection makes this path ineligible for an exception.
static int zb_directory_protection(int fd) {
	struct stat info;
	if (fstat(fd, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != geteuid()) return 0;
	acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
	// On macOS an existing, fstat-verified directory without an extended ACL
	// returns ENOENT. Other failures must not establish a private boundary.
	if (acl == NULL) return errno == ENOENT ? ((info.st_mode & 0077) == 0 ? 2 : 1) : 0;
	if (acl_valid(acl) != 0) { acl_free(acl); return 0; }
	acl_entry_t entry;
	int next = ACL_FIRST_ENTRY;
	errno = 0;
	while (acl_get_entry(acl, next, &entry) == 0) {
		acl_tag_t tag;
		if (acl_get_tag_type(entry, &tag) != 0 || tag != ACL_EXTENDED_DENY) {
			acl_free(acl);
			return 0;
		}
		next = ACL_NEXT_ENTRY;
		errno = 0;
	}
	int end_error = errno;
	acl_free(acl);
	// macOS reports EINVAL at the end of a valid ACL (including an empty ACL).
	if (end_error != EINVAL) return 0;
	return (info.st_mode & 0077) == 0 ? 2 : 1;
}
*/
import "C"

import "os"

func directoryProtection(directory *os.File) (trusted, private bool) {
	protection := C.zb_directory_protection(C.int(directory.Fd()))
	return protection != 0, protection == 2
}
