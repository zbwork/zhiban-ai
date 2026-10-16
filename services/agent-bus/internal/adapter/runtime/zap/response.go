package zap

import (
	"io"
	"net/http"
)

const (
	maxJSONResponseBytes  = 8 * 1024 * 1024
	maxErrorResponseBytes = 64 * 1024
	responseTooLargeCode  = "zap.response_too_large"
	responseReadCode      = "zap.response_read_failed"
)

// readJSONResponse separates the protocol body limit from the call-log display
// limit. Never pass partial JSON to decoding or logging (including on read errors).
func readJSONResponse(resp *http.Response) ([]byte, string) {
	limit := int64(maxJSONResponseBytes)
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		limit = maxErrorResponseBytes
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if int64(len(raw)) > limit {
		return nil, responseTooLargeCode
	}
	if err != nil {
		return nil, responseReadCode
	}
	return raw, ""
}
