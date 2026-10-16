// Package sms 是短信发送的端口与默认 stub 实现。
//
// 真实部署接入运营商(阿里云 / 腾讯云 / Twilio 等)时再加 sub-package, 满足
// Sender 接口即可。本期默认 stub 仅做日志输出, 方便本地与测试库联调。
package sms

import (
	"context"
)

// Sender 发送短信。
type Sender interface {
	Send(ctx context.Context, mobile, content string) error
}

// externalDeliveryReporter is an optional capability implemented by senders
// that intentionally do not deliver outside the process (for example stdout).
// Real providers and existing third-party senders remain externally capable by
// default for backward compatibility.
type externalDeliveryReporter interface {
	ExternalDeliveryEnabled() bool
}

// ExternalDeliveryEnabled reports whether a successful Send means that the
// message was handed to an external delivery provider.
func ExternalDeliveryEnabled(sender Sender) bool {
	reporter, ok := sender.(externalDeliveryReporter)
	return !ok || reporter.ExternalDeliveryEnabled()
}
