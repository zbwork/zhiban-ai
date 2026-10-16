package runtimeenv

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

const ExternalEnvironmentIDMaxLength = 256

// NormalizeExternalEnvironmentID keeps the external reference a stable,
// single-line string. It is metadata for the peer runtime, never an EasyO
// identity or authorization input.
func NormalizeExternalEnvironmentID(value string) (string, error) {
	normalized := strings.TrimSpace(value)
	if utf8.RuneCountInString(normalized) > ExternalEnvironmentIDMaxLength {
		return "", fmt.Errorf("external_environment_id must be at most %d characters", ExternalEnvironmentIDMaxLength)
	}
	for _, r := range normalized {
		if unicode.IsControl(r) {
			return "", fmt.Errorf("external_environment_id must be a single-line string without control characters")
		}
	}
	return normalized, nil
}
