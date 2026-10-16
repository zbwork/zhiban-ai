//go:build !darwin && !windows

package detect

import "errors"

// NewSystemDetector fails on platforms with no detector wired.
func NewSystemDetector(string) (*Detector, error) {
	return nil, errors.New("detect: unsupported platform")
}
