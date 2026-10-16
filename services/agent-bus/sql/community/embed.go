// Package community contains the independent community schema and safe seeds.
package community

import "embed"

// Files is the immutable migration set shipped with the executable.
//
//go:embed *.up.sql
var Files embed.FS
