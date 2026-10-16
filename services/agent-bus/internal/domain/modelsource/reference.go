package modelsource

import "strings"

// IsReference recognizes selection and execution reference namespaces.
// It does not validate or authorize the referenced model.
func IsReference(id string) bool {
	return strings.HasPrefix(id, "mref:") || strings.HasPrefix(id, "msel:") || strings.HasPrefix(id, "mbnd:")
}
