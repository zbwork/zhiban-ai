//go:build windows

package detect

// NewSystemDetector returns the Windows detector.
func NewSystemDetector(homeDir string) (*Detector, error) {
	return NewWindowsDetector(homeDir)
}
