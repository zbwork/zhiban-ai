package install

import (
	"archive/tar"
	"compress/gzip"
	"errors"
	"io"
	"path"
	"strings"
)

const maxExtractedBytes = 512 << 20

var errArchiveInvalid = errors.New("install: archive layout not recognised")

// extractSingleExecutable reads a gzip tarball that must contain exactly one
// regular file (directories and PAX headers are tolerated) and streams that
// file into sink. Symlinks, hard links, devices, absolute names and path
// traversal are rejected before any byte reaches sink.
func extractSingleExecutable(archive io.Reader, sink func(io.Reader, int64) error) error {
	decompressed, err := gzip.NewReader(archive)
	if err != nil {
		return errArchiveInvalid
	}
	defer decompressed.Close()
	reader := tar.NewReader(decompressed)
	extracted := false
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return errArchiveInvalid
		}
		if !safeArchiveName(header.Name) {
			return errArchiveInvalid
		}
		switch header.Typeflag {
		case tar.TypeDir, tar.TypeXGlobalHeader, tar.TypeXHeader:
			continue
		case tar.TypeReg:
			if extracted || header.Size <= 0 || header.Size > maxExtractedBytes {
				return errArchiveInvalid
			}
			if err := sink(io.LimitReader(reader, header.Size), header.Size); err != nil {
				return err
			}
			extracted = true
		default:
			return errArchiveInvalid
		}
	}
	if !extracted {
		return errArchiveInvalid
	}
	return nil
}

// extractMember streams exactly the named regular member of a gzip tarball
// into sink. Other entries are skipped without being extracted; the member
// must be present exactly once and must be a regular file.
func extractMember(archive io.Reader, member string, sink func(io.Reader, int64) error) error {
	if !safeArchiveName(member) {
		return errArchiveInvalid
	}
	decompressed, err := gzip.NewReader(archive)
	if err != nil {
		return errArchiveInvalid
	}
	defer decompressed.Close()
	reader := tar.NewReader(decompressed)
	extracted := false
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return errArchiveInvalid
		}
		if path.Clean(header.Name) != member {
			continue
		}
		if extracted || header.Typeflag != tar.TypeReg || header.Size <= 0 || header.Size > maxExtractedBytes {
			return errArchiveInvalid
		}
		if err := sink(io.LimitReader(reader, header.Size), header.Size); err != nil {
			return err
		}
		extracted = true
	}
	if !extracted {
		return errArchiveInvalid
	}
	return nil
}

const (
	// maxTreeBytes and maxTreeEntries bound a package tree extraction (the
	// Codex package is four executables plus resources, ~600 MB unpacked).
	maxTreeBytes   = 2 << 30
	maxTreeEntries = 4096
	maxTreeDepth   = 16
)

// extractTree streams every regular file below the prefix directory of a
// gzip tarball into visit, with the member's path relative to prefix
// ("/"-separated) and whether the publisher marked it executable. Directory
// entries are implied by the file paths. Entries outside prefix are skipped;
// inside it, anything but a regular file or directory (symlinks, hard links,
// devices) and any traversal reject the archive before a byte is extracted.
func extractTree(archive io.Reader, prefix string, visit func(relative string, executable bool, content io.Reader, size int64) error) error {
	if !safeArchiveName(prefix) || path.Clean(prefix) != prefix {
		return errArchiveInvalid
	}
	decompressed, err := gzip.NewReader(archive)
	if err != nil {
		return errArchiveInvalid
	}
	defer decompressed.Close()
	reader := tar.NewReader(decompressed)
	entries := 0
	var total int64
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return errArchiveInvalid
		}
		if !safeArchiveName(header.Name) {
			return errArchiveInvalid
		}
		name := path.Clean(header.Name)
		if name == prefix || !strings.HasPrefix(name, prefix+"/") {
			continue
		}
		relative := strings.TrimPrefix(name, prefix+"/")
		switch header.Typeflag {
		case tar.TypeDir, tar.TypeXGlobalHeader, tar.TypeXHeader:
			continue
		case tar.TypeReg:
		default:
			return errArchiveInvalid
		}
		if !safeRelativeTreePath(relative) || header.Size < 0 || header.Size > maxExtractedBytes {
			return errArchiveInvalid
		}
		entries++
		total += header.Size
		if entries > maxTreeEntries || total > maxTreeBytes {
			return errArchiveInvalid
		}
		executable := header.FileInfo().Mode()&0o111 != 0
		if err := visit(relative, executable, io.LimitReader(reader, header.Size), header.Size); err != nil {
			return err
		}
	}
	if entries == 0 {
		return errArchiveInvalid
	}
	return nil
}

// safeRelativeTreePath accepts "dir/sub/file" style paths: every component
// non-empty, not "." or "..", no separators other than "/", bounded depth.
func safeRelativeTreePath(relative string) bool {
	if relative == "" || strings.ContainsAny(relative, "\\\x00") {
		return false
	}
	parts := strings.Split(relative, "/")
	if len(parts) > maxTreeDepth {
		return false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func safeArchiveName(name string) bool {
	if name == "" || strings.HasPrefix(name, "/") || strings.ContainsRune(name, 0) {
		return false
	}
	clean := path.Clean(name)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || strings.Contains(clean, "/../") {
		return false
	}
	return true
}
