package modelerror

import "errors"

// Failure carries only allowlisted public data, never vendor text or credentials.
type Failure struct {
	Code   string
	Status int
}

func (e *Failure) Error() string {
	if e == nil {
		return "model request failed"
	}
	if message := Message(e.Code, e.Status); message != "" {
		return message
	}
	return "model request failed"
}

// Details recognizes only typed failures; arbitrary error text is never classified or exposed.
func Details(err error) (code, message string, status int) {
	var failure *Failure
	if !errors.As(err, &failure) || failure == nil {
		return "", "", 0
	}
	if failure.Status >= 300 && failure.Status <= 599 {
		status = failure.Status
	}
	message = Message(failure.Code, status)
	if message == "" {
		return "", "", 0
	}
	return failure.Code, message, status
}

func HTTPFailure(status int) error {
	code := "model.upstream_failure"
	switch {
	case status >= 300 && status < 400:
		code = "model.redirect_not_allowed"
	case status == 401 || status == 403:
		code = "model.authentication_failed"
	case status == 404:
		code = "model.unavailable"
	case status == 408 || status == 504:
		code = "model.timeout"
	case status == 429:
		code = "model.rate_limited"
	case status >= 400 && status < 500:
		code = "model.request_invalid"
	}
	return &Failure{Code: code, Status: status}
}
