//go:build darwin

package detect

// NewSystemDetector returns the macOS detector.
func NewSystemDetector(homeDir string) (*Detector, error) {
	return NewMacOSDetector(homeDir)
}
