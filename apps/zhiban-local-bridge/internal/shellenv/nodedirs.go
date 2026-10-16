package shellenv

import (
	"context"
	"os"
	"path/filepath"
	"strings"
)

// NodeDirs returns the directories to put in front of a sanitized PATH so a
// CLI installed through npm — a `#!/usr/bin/env node` launcher — can start
// when the Bridge runs it (version probe, post-switch probe, L3 verification).
// First the bin of the Node prefix the package was installed under
// (nvm / fnm / asdf / mise / Homebrew keep node right there), then the
// directory of the node the user's login shell runs (custom npm prefixes,
// bun, volta). Only directories holding an executable regular `node` file are
// returned, and nothing at all for an executable that is not a node script
// (native binaries never need it). lookup may be nil and is only asked when
// the package's own prefix has no node.
func NodeDirs(ctx context.Context, executable string, lookup *LoginShellLookup) []string {
	if executable == "" {
		return nil
	}
	real := executable
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		real = resolved
	}
	if !nodeScript(real) {
		return nil
	}
	dirs := make([]string, 0, 2)
	add := func(dir string) {
		dir = filepath.Clean(dir)
		if !executableFile(filepath.Join(dir, nodeBinaryName)) {
			return
		}
		for _, existing := range dirs {
			if existing == dir {
				return
			}
		}
		dirs = append(dirs, dir)
	}
	separator := string(filepath.Separator)
	if index := strings.Index(real, separator+filepath.Join("lib", "node_modules")+separator); index > 0 {
		add(filepath.Join(real[:index], "bin"))
	}
	if len(dirs) == 0 {
		if node, ok := lookup.Lookup(ctx, "node"); ok {
			add(filepath.Dir(node))
		}
	}
	return dirs
}

// nodeScript reports whether path starts with a shebang naming node.
func nodeScript(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	head := make([]byte, 128)
	n, _ := file.Read(head)
	line, _, _ := strings.Cut(string(head[:n]), "\n")
	return strings.HasPrefix(line, "#!") && strings.Contains(line, "node")
}

// PrependPath returns environment with dirs in front of its PATH entry.
func PrependPath(environment []string, dirs []string) []string {
	if len(dirs) == 0 {
		return environment
	}
	result := append([]string(nil), environment...)
	prefix := strings.Join(dirs, string(filepath.ListSeparator))
	for index, item := range result {
		if value, ok := strings.CutPrefix(item, "PATH="); ok {
			if value == "" {
				result[index] = "PATH=" + prefix
			} else {
				result[index] = "PATH=" + prefix + string(filepath.ListSeparator) + value
			}
			return result
		}
	}
	return append(result, "PATH="+prefix)
}

func executableFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}
