// Package auth · QR 扫码登录 (zhiban-app cutover, docs/contracts/agent-bus-client-contract.md §10.4)。
//
// 设计:
//   - 桌面端无身份调 POST /auth/qr/create 拿 {qrcodeKey, qrcodeImage}, 渲染二维码 (payload =
//     "agentbus-qr:<key>") 并 2s 一次轮询 GET /auth/qr/status。
//   - 已登录的移动端扫描后扫码页解析出 key, 弹"登录桌面端?"弹窗:
//   - 用户确认 → POST /auth/qr/confirm (auth 必填, 复用 mobile 当前 actScope 给桌面签新 token)
//   - 用户取消 → POST /auth/qr/cancel
//     扫描时先 POST /auth/qr/scan 把 status flip 到 "scanned" 让桌面 UI 立刻反馈"已扫描"。
//   - 桌面端轮询命中 confirmed → 从响应取 accessToken/refreshToken, 写入 SharedPreferences, 进主页。
//
// 状态机: pending → scanned → confirmed | cancelled | expired (任何状态 + ttl 过 → expired)。
// 终态 (confirmed/cancelled/expired) 后 status 仍可被读取直到 Redis TTL 到期; client 收到终态后停止轮询。
//
// Redis schema (key 前缀 "agbus:auth:qr:"):
//
//	value 是 JSON-encoded qrSession; TTL = ttl (5min, 与 captcha 同步)。
package auth

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
	qrcode "github.com/skip2/go-qrcode"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/session"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const (
	qrKeyPfx       = "agbus:auth:qr:"
	qrTTL          = 5 * time.Minute
	qrPayloadProto = "agentbus-qr:" // QR 内容前缀
)

// QR session 在 Redis 中的存档结构。
type qrSession struct {
	Key       string     `json:"key"`
	Status    string     `json:"status"` // pending / scanned / confirmed / cancelled / expired
	CreatedAt time.Time  `json:"createdAt"`
	Device    DeviceInfo `json:"device"`

	// 已确认时填: confirm handler 把 mobile caller 的 (account, tenant) 镜像下来, 桌面轮询拿出。
	AccountID    int64  `json:"accountId,omitempty"`
	TenantID     int64  `json:"tenantId,omitempty"`
	AccessToken  string `json:"accessToken,omitempty"`
	RefreshToken string `json:"refreshToken,omitempty"`
	RefreshExp   int64  `json:"refreshExp,omitempty"` // unix sec; 兼容客户端再做秒级展示
}

// ===== DTO =====

// QRCreateResp POST /auth/qr/create 响应。
type QRCreateResp struct {
	QRCodeKey     string `json:"qrcodeKey"`
	QRCodeImage   string `json:"qrcodeImage"`   // data:image/png;base64,...
	QRCodePayload string `json:"qrcodePayload"` // 仅供调试/扫码侧自检; 已编码进 image
	ExpireSeconds int    `json:"expireSeconds"`
}

// QRStatusResp GET /auth/qr/status?key= 响应。
// confirmed 状态额外带 LoginResp 字段; 其它状态只回 status + statusDesc。
type QRStatusResp struct {
	Status     string   `json:"status"`
	StatusDesc string   `json:"statusDesc"`
	Login      *qrLogin `json:"login,omitempty"`
}

type qrLogin struct {
	AccessToken           string         `json:"accessToken"`
	AccessTokenExpiresAt  time.Time      `json:"accessTokenExpiresAt"`
	RefreshToken          string         `json:"refreshToken"`
	RefreshTokenExpiresAt time.Time      `json:"refreshTokenExpiresAt"`
	Account               AccountSummary `json:"account"`
	ActScope              ScopeOption    `json:"actScope"`
}

// QRConfirmReq POST /auth/qr/confirm body。
//
// 默认 (tenantId == 0) 使用 mobile caller 当前 actScope 给桌面端签 token;
// 显式 tenantId 时必须在 caller 可访问 scope 列表内。
type QRConfirmReq struct {
	Key      string     `json:"key"`
	TenantID int64      `json:"tenantId,omitempty"`
	Device   DeviceInfo `json:"device,omitempty"`
}

// QRKeyReq /auth/qr/{scan,cancel} body, 只用 key。
type QRKeyReq struct {
	Key string `json:"key"`
}

// ===== QRService =====

// QRService 二维码登录子服务。bus 进程独立装配; admin 进程不需要。
type QRService struct {
	rdb *redis.Client
	// 复用 auth.Service 自身的发 token 流水: confirm 时调 auth.impl.issueLoginForQR 拿到
	// accessToken/refreshToken/actScope。这里走"指向 *impl"形式而不是 interface, 因为
	// 我们要复用 issueLogin 的私有 helper (buildScopeOptions / issueAccessToken / Sessions.Create
	// 等), 把它们暴露成 public interface 反而泄露太多内部细节。
	auth     *impl
	accounts account.Repository
	sessions session.Repository
}

// NewQRService 构造。
func NewQRService(rdb *redis.Client, authSvc Service, accounts account.Repository, sessions session.Repository) *QRService {
	im, _ := authSvc.(*impl)
	return &QRService{rdb: rdb, auth: im, accounts: accounts, sessions: sessions}
}

// Create 桌面端拉一张二维码 (不挂 auth)。
func (s *QRService) Create(ctx context.Context, devices ...DeviceInfo) (*QRCreateResp, error) {
	if s.rdb == nil {
		return nil, apperr.ErrInternal.Withf("qr login: redis unavailable")
	}
	key, err := newQRKey()
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	payload := qrPayloadProto + key
	png, err := qrcode.Encode(payload, qrcode.Medium, 256)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	device := DeviceInfo{Type: "desktop"}
	if len(devices) > 0 && session.DeviceClass(devices[0].Type) == "desktop" {
		device = devices[0]
	}
	sess := qrSession{Key: key, Status: "pending", CreatedAt: time.Now(), Device: device}
	if err := s.put(ctx, &sess); err != nil {
		return nil, err
	}
	dataURI := "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
	return &QRCreateResp{
		QRCodeKey:     key,
		QRCodeImage:   dataURI,
		QRCodePayload: payload,
		ExpireSeconds: int(qrTTL / time.Second),
	}, nil
}

// Status 桌面端轮询; key 不存在视为 expired (与"过期"语义一致, 客户端展示统一)。
func (s *QRService) Status(ctx context.Context, key string) (*QRStatusResp, error) {
	if key == "" {
		return nil, apperr.ErrInvalidParams.Withf("key required")
	}
	sess, err := s.get(ctx, key)
	if err != nil {
		return nil, err
	}
	if sess == nil {
		return &QRStatusResp{Status: "expired", StatusDesc: "二维码已过期，请刷新重试"}, nil
	}
	resp := &QRStatusResp{Status: sess.Status, StatusDesc: qrStatusDesc(sess.Status)}
	if sess.Status == "confirmed" && sess.AccessToken != "" {
		// 重新从 accounts + sessions 拼 LoginResp; 不要把整 LoginResp 写 Redis (含 mutable summary)。
		acc, err := s.accounts.GetByID(ctx, sess.AccountID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		scope, _ := s.auth.buildScopeOption(ctx, sess.AccountID, "tenant", ptr(sess.TenantID), nil)
		resp.Login = &qrLogin{
			AccessToken:           sess.AccessToken,
			AccessTokenExpiresAt:  time.Now().Add(s.auth.d.AccessTTL),
			RefreshToken:          sess.RefreshToken,
			RefreshTokenExpiresAt: time.Unix(sess.RefreshExp, 0),
			Account:               s.auth.summarizeAccount(ctx, sess.TenantID, acc, false),
			ActScope:              scope,
		}
	}
	return resp, nil
}

// Scan 移动端扫描后调用 (auth 必填)。仅状态翻转, 不签 token; 桌面端轮询会看到 status=scanned。
func (s *QRService) Scan(ctx context.Context, accountID int64, key string) error {
	if accountID <= 0 || key == "" {
		return apperr.ErrInvalidParams.Withf("account/key required")
	}
	return s.transition(ctx, key, func(sess *qrSession) error {
		if sess.Status != "pending" {
			return apperr.ErrConflict.Withf("二维码状态不可扫描: %s", sess.Status)
		}
		sess.Status = "scanned"
		return nil
	})
}

// Confirm 移动端 "同意登录"; 用 caller 当前 (或显式 req.TenantID) scope 给桌面签 access/refresh token。
//
// ac.IP / ac.UserAgent 是 mobile caller 的, 但落到桌面 login_sessions 行更合理是桌面 IP/UA;
// 桌面端在 Create 时并未鉴权也拿不到稳定 UA, 这里先用 mobile 的 (审计意义: "谁授权了哪台设备")。
func (s *QRService) Confirm(ctx context.Context, ac AuthContext, accountID int64, currentTenantID int64, req QRConfirmReq) error {
	if accountID <= 0 || req.Key == "" {
		return apperr.ErrInvalidParams.Withf("account/key required")
	}
	tid := req.TenantID
	if tid == 0 {
		tid = currentTenantID
	}
	if tid == 0 {
		return apperr.ErrInvalidParams.Withf("tenantId required (caller not in tenant scope)")
	}
	return s.transition(ctx, req.Key, func(sess *qrSession) error {
		if sess.Status != "scanned" && sess.Status != "pending" {
			return apperr.ErrConflict.Withf("二维码状态不可确认: %s", sess.Status)
		}
		// 校 caller 可访问该 tenant
		scope, err := s.auth.buildScopeOption(ctx, accountID, "tenant", ptr(tid), nil)
		if err != nil {
			return err
		}
		if scope.TenantID == 0 {
			return apperr.ErrForbidden.Withf("无访问该租户的权限")
		}
		acc, err := s.accounts.GetByID(ctx, accountID)
		if err != nil {
			return err
		}
		// Device belongs to the QR-creating desktop, never the confirming phone.
		device := sess.Device
		if session.DeviceClass(device.Type) != "desktop" {
			device = DeviceInfo{Type: "desktop"}
		}
		// 给桌面端开一条新 session + access/refresh; 落表 acting_as="qr_login" 留痕。
		refresh, refreshHash := newRefreshToken()
		tidP := tid
		sessRow, err := s.sessions.Create(ctx, session.CreateInput{
			AccountID:           accountID,
			RefreshTokenHash:    refreshHash,
			ExpiresAt:           time.Now().Add(s.auth.d.RefreshTTL),
			ActScopeKind:        "tenant",
			ActTenantID:         &tidP,
			ActingAs:            "qr_login",
			UserAgent:           ac.UserAgent,
			IP:                  ac.IP,
			DeviceFingerprint:   device.Fingerprint,
			DeviceType:          device.Type,
			DeviceBrand:         device.Brand,
			DeviceModel:         device.Model,
			DeviceSystemVersion: device.SystemVersion,
			DeviceAppVersion:    device.AppVersion,
		})
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		tok, err := s.auth.issueAccessToken(acc, sessRow.UUID, scope)
		if err != nil {
			return err
		}
		sess.Status = "confirmed"
		sess.AccountID = accountID
		sess.TenantID = tid
		sess.AccessToken = tok
		sess.RefreshToken = refresh
		sess.RefreshExp = sessRow.ExpiresAt.Unix()
		return nil
	})
}

// Cancel 移动端 "取消授权"。
func (s *QRService) Cancel(ctx context.Context, accountID int64, key string) error {
	if accountID <= 0 || key == "" {
		return apperr.ErrInvalidParams.Withf("account/key required")
	}
	return s.transition(ctx, key, func(sess *qrSession) error {
		if sess.Status == "confirmed" {
			return apperr.ErrConflict.Withf("已确认登录, 无法取消")
		}
		sess.Status = "cancelled"
		return nil
	})
}

// ===== 内部 Redis helper =====

func (s *QRService) get(ctx context.Context, key string) (*qrSession, error) {
	raw, err := s.rdb.Get(ctx, qrKeyPfx+key).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	var sess qrSession
	if err := json.Unmarshal(raw, &sess); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return &sess, nil
}

func (s *QRService) put(ctx context.Context, sess *qrSession) error {
	buf := bytes.Buffer{}
	if err := json.NewEncoder(&buf).Encode(sess); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if err := s.rdb.Set(ctx, qrKeyPfx+sess.Key, buf.Bytes(), qrTTL).Err(); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}

// transition load → mutate → save; mutate 内部决定状态校验。
//
// 注意 *非* 原子: Redis 没有事务 (SETEX 不带 CAS); 同一 key 并发 confirm + cancel 时按"最后写入胜出"。
// QR 登录场景下用户单设备扫码, 极少并发, 暂可接受; 强一致诉求未来用 SETNX + version 号补。
func (s *QRService) transition(ctx context.Context, key string, mutator func(*qrSession) error) error {
	sess, err := s.get(ctx, key)
	if err != nil {
		return err
	}
	if sess == nil {
		return apperr.ErrNotFound.Withf("二维码已过期")
	}
	if err := mutator(sess); err != nil {
		return err
	}
	return s.put(ctx, sess)
}

func qrStatusDesc(status string) string {
	switch status {
	case "pending":
		return "请使用手机 知办AI 扫码登录"
	case "scanned":
		return "已扫描，请在手机上确认"
	case "confirmed":
		return "登录成功"
	case "cancelled":
		return "已取消登录"
	case "expired":
		return "二维码已过期，请刷新重试"
	default:
		return status
	}
}

func newQRKey() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("rand.Read: %w", err)
	}
	return hex.EncodeToString(raw[:]), nil
}

// 兼容旧 imports linter; bytes 用于序列化 buffer。
var _ = strings.TrimSpace
