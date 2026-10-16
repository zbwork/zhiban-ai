package errors

import (
	"errors"
	"fmt"
)

// Code 标准错误码（HTTP 状态码 + 业务码混合）。
type Code int

const (
	OK                  Code = 0
	InvalidParams       Code = 4000
	Unauthorized        Code = 4010
	PaymentRequired     Code = 4020
	Forbidden           Code = 4030
	NotFound            Code = 4040
	Conflict            Code = 4090
	PreconditionFailed  Code = 4120
	TooManyRequests     Code = 4290
	InternalError       Code = 5000
	UpstreamUnavailable Code = 5020
)

// Error 业务错误。
type Error struct {
	Code    Code
	Message string
	Cause   error
}

func New(code Code, message string) *Error {
	return &Error{Code: code, Message: message}
}

func (e *Error) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("[%d] %s: %v", e.Code, e.Message, e.Cause)
	}
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

func (e *Error) Unwrap() error { return e.Cause }

// Wrap 包装一个底层错误。
func (e *Error) Wrap(err error) *Error {
	cp := *e
	cp.Cause = err
	return &cp
}

// Withf 追加 message 上下文。
func (e *Error) Withf(format string, args ...any) *Error {
	cp := *e
	cp.Message = fmt.Sprintf("%s: "+format, append([]any{e.Message}, args...)...)
	return &cp
}

// HTTPStatus 返回对应的 HTTP 状态码。
//
// 注意 case 顺序：先匹配较窄的 401/403/404/409/429 子段，再兜底 4xxx → 400。
// 之前的版本把 `4000..4100 → 400` 放在最前，导致 Forbidden(4030) 错误地返 400。
func (e *Error) HTTPStatus() int {
	switch {
	case e.Code == OK:
		return 200
	case e.Code >= 4010 && e.Code < 4020:
		return 401
	case e.Code >= 4020 && e.Code < 4030:
		return 402
	case e.Code >= 4030 && e.Code < 4040:
		return 403
	case e.Code >= 4040 && e.Code < 4050:
		return 404
	case e.Code >= 4090 && e.Code < 4100:
		return 409
	case e.Code >= 4120 && e.Code < 4130:
		return 412
	case e.Code >= 4290 && e.Code < 4300:
		return 429
	case e.Code >= 4000 && e.Code < 4100:
		return 400
	case e.Code == UpstreamUnavailable:
		return 502
	default:
		return 500
	}
}

// AsError 提取 *Error。
func AsError(err error) (*Error, bool) {
	var e *Error
	if errors.As(err, &e) {
		return e, true
	}
	return nil, false
}

// 预置错误。
var (
	ErrInvalidParams      = New(InvalidParams, "invalid params")
	ErrUnauthorized       = New(Unauthorized, "unauthorized")
	ErrPaymentRequired    = New(PaymentRequired, "payment required")
	ErrForbidden          = New(Forbidden, "forbidden")
	ErrNotFound           = New(NotFound, "not found")
	ErrConflict           = New(Conflict, "conflict")
	ErrPreconditionFailed = New(PreconditionFailed, "precondition failed")
	ErrInternal           = New(InternalError, "internal error")
	// ErrUpstreamUnavailable 用于上游 (Runtime / 第三方 API) 调用失败;
	// HTTP 502/503; client 应看到具体原因 (而不是泛泛的 "internal error")。
	ErrUpstreamUnavailable = New(UpstreamUnavailable, "upstream unavailable")
)
