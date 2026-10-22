// Package oauth2 是 F04 (apps) + F01 (agent SDK) 共享的 OAuth2 公共代码。
//
// 子包:
//   - oauth2/ratelimit  : per-client_id token bucket; F01 §3.6 + F04 §3.5 共用
//   - oauth2/jwt        : RS256 JWT 签 / 验 (id_token + access_token); F04 专用
//   - oauth2/keys       : KeyManager 接口 + Postgres 实现; F04 专用 (oauth_signing_keys 表)
//
// 顶层文件:
//   - client_secret.go  : GenClientID / GenSecret / HashSecret / VerifySecret
//     (常时间比对; 防时序攻击)
//
// 定位:
//   - 这里只放 "通用 OAuth2 协议层" 代码; 业务逻辑 (apps service, agent SDK service)
//     在 internal/service/ 下。
//   - 跟 internal/pkg/jwt/ (Ed25519 用户登录 JWT) 不冲突 — 算法 / 用途 / 受众都不一样。
//   - 跟 internal/pkg/ratelimit/ (空) 不冲突 — 那里规划存通用限流原语;
//     OAuth 特化的限流逻辑放本子包。
package oauth2
