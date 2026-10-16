package detect

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

const maxVersionOutputBytes = 4096

var semanticVersionPattern = regexp.MustCompile(`\b[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?\b`)

type VersionProber struct {
	Timeout time.Duration
	HomeDir string
	// NodeLookup finds the Node runtime an npm launcher needs when node is
	// not beside it (custom npm prefix, bun, volta). Optional.
	NodeLookup *shellenv.LoginShellLookup
}

func (p VersionProber) Probe(ctx context.Context, targetID string, candidate Candidate) (string, error) {
	if codexLayoutIncomplete(targetID, candidate) {
		return "", ErrLayoutIncomplete
	}
	timeout := p.Timeout
	if timeout <= 0 || timeout > 10*time.Second {
		timeout = 2 * time.Second
	}
	probeContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command := exec.CommandContext(probeContext, candidate.RealPath, "--version")
	command.Dir = p.HomeDir
	command.Env = []string{
		"HOME=" + p.HomeDir,
		"LANG=C",
		"LC_ALL=C",
		"PATH=" + probePath(candidate, shellenv.NodeDirs(ctx, candidate.RealPath, p.NodeLookup)),
	}
	var output cappedBuffer
	command.Stdout = &output
	command.Stderr = &cappedBuffer{}
	err := command.Run()
	if errors.Is(probeContext.Err(), context.DeadlineExceeded) {
		return "", ErrProbeTimeout
	}
	if err != nil {
		return "", ErrProbeFailed
	}
	if output.overflow {
		return "", ErrVersionUnrecognized
	}
	return parseVersion(targetID, output.Bytes())
}

func probePath(candidate Candidate, nodeDirs []string) string {
	parts := []string{filepath.Dir(candidate.Path), filepath.Dir(candidate.RealPath)}
	parts = append(parts, nodeDirs...)
	parts = append(parts, "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	seen := make(map[string]struct{}, len(parts))
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		part = filepath.Clean(part)
		if _, duplicate := seen[part]; duplicate {
			continue
		}
		seen[part] = struct{}{}
		result = append(result, part)
	}
	return strings.Join(result, string(filepath.ListSeparator))
}

func parseVersion(targetID string, output []byte) (string, error) {
	if targetID != TargetCodexCLI && targetID != TargetClaudeCLI {
		return "", ErrUnsupportedTarget
	}
	if len(output) == 0 || len(output) > maxVersionOutputBytes {
		return "", ErrVersionUnrecognized
	}
	match := semanticVersionPattern.Find(output)
	if len(match) == 0 {
		return "", ErrVersionUnrecognized
	}
	return string(match), nil
}

type cappedBuffer struct {
	buffer   bytes.Buffer
	overflow bool
}

func (w *cappedBuffer) Write(data []byte) (int, error) {
	originalLength := len(data)
	remaining := maxVersionOutputBytes + 1 - w.buffer.Len()
	if remaining <= 0 {
		w.overflow = true
		return originalLength, nil
	}
	if len(data) > remaining {
		data = data[:remaining]
		w.overflow = true
	}
	_, err := w.buffer.Write(data)
	if err != nil {
		return 0, fmt.Errorf("buffer version output: %w", err)
	}
	return originalLength, nil
}

func (w *cappedBuffer) Bytes() []byte {
	return w.buffer.Bytes()
}
