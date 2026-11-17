// Package identity contains non-secret public identity-provider directory types.
package identity

type PublicProvider struct {
	UUID string `json:"uuid"`
	Name string `json:"name"`
	Kind string `json:"kind"`
}
