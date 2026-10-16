package encode

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Response 统一响应外壳。
//
// 字段命名按 zhiban-app `ResDataModel` 约定 (camelCase: success/code/message/data/traceId),
// 客户端 ResponseInterceptor 按 success/data 字段做提取与失败兜底。
type Response struct {
	Success bool        `json:"success"`
	Code    errors.Code `json:"code"`
	Message string      `json:"message"`
	Data    any         `json:"data,omitempty"`
	TraceID string      `json:"traceId,omitempty"`
}

// JSON 写一个成功响应。
func JSON(w http.ResponseWriter, data any) {
	JSONStatus(w, http.StatusOK, data)
}

// JSONStatus 写一个带自定义 2xx HTTP 状态的成功响应。
// Content-Type 必须在 WriteHeader 前设置，否则浏览器无法按 JSON 解析响应。
func JSONStatus(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(Response{Success: true, Code: errors.OK, Message: "ok", Data: data})
}

// JSONErrorWithCode 写一个自定义 HTTP 状态 + 业务码 body 的错误响应。
//
// 用于 Batch 2C T2C.3 OpenClaw 同步失败 (409 + openclaw_sync_failed) 等场景:
// 标准 JSONError 的 code 字段固定来自 errors.Code, 不便于业务自定义错误码。
// 这里直接让 caller 传入 body, body 至少应含 {code, message}。
func JSONErrorWithCode(w http.ResponseWriter, httpStatus int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(httpStatus)
	// 包一层 success=false 外壳, 仍兼容客户端 ResponseInterceptor.
	_ = json.NewEncoder(w).Encode(Response{Success: false, Code: errors.Conflict, Message: "conflict", Data: body})
}

// JSONError 写一个错误响应。
//
// 5xx 错误同时把原始 err (含 SQL/IO 详细原因) 输出到 stderr, 便于本地排查;
// 客户端只看到通用的 "internal error", 避免泄露内部错误细节。
func JSONError(w http.ResponseWriter, err error) {
	e, ok := errors.AsError(err)
	if !ok {
		e = errors.ErrInternal.Wrap(err)
	}
	if e.HTTPStatus() >= 500 {
		slog.Error("encode.5xx", "error", e.Error(), "underlying", err)
	}
	// UpstreamUnavailable: 显式把 underlying error 拼进 Message, 便于排查 sandbox/runtime 调用失败。
	if e.Code == errors.UpstreamUnavailable && e.Cause != nil && e.Message == "upstream unavailable" {
		e = errors.New(e.Code, fmt.Sprintf("upstream unavailable: %v", e.Cause))
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(e.HTTPStatus())
	_ = json.NewEncoder(w).Encode(Response{Success: false, Code: e.Code, Message: e.Message})
}
