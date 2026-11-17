package external

import (
	"encoding/json"
	"io"
)

// decodeStrictJSON rejects removed, misspelled, and otherwise unknown request fields.
func decodeStrictJSON(body io.Reader, dst any) error {
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	return decoder.Decode(dst)
}
