// Package runtimetype 是"Agent 平台类型" L1 只读注册中心。
//
// 4 层 Agent 平台模型 (docs/design/agent-bus-admin-and-runtime-capabilities-design.md §2.3):
//
//	L1 平台类型  —— 本包: 代码常量 + readonly API
//	L2 平台托管配置 —— internal/service/runtimehosting
//	L3 租户 Agent 环境 —— internal/service/runtimeenv
//	L4 数字员工运行配置 —— internal/service/agent (绑 runtime_registration_id)
//
// 新增平台类型 = 必须先有后端 adapter 代码 (adapter/runtime/<framework>/...);
// admin UI 不允许 CRUD, 只读展示。
package runtimetype

import "strings"

import "context"

// Framework code: 4 层模型 L1 的稳定枚举值 (ADR-0023 后回归 zap)。
const (
	FrameworkOpenclaw = "openclaw"
	FrameworkHermes   = "hermes"
	FrameworkZAP      = "zap"
	// FrameworkDSH 平台自营「知办通用运行时（dsh）」(ADR-0035 修订): 线协议仍是 ZAP (external_endpoint),
	// 但作为一等内置执行器享受平台策略 (KB 预检索、用户 key 必注入、技能绑定、人设下发、用量归账)。
	FrameworkDSH = "dsh"
)

// Type 是一份平台类型的元数据。
type Type struct {
	Code        string `json:"code"`         // 稳定枚举值: openclaw | hermes | zap (ADR-0023: 协议本体一直叫 ZAP, framework 列同步对齐)
	DisplayName string `json:"display_name"` // UI 展示名
	Description string `json:"description"`  // 简短说明
	// DocAnchor 指向 /runtime-environment-protocol?type=<code> 的章节
	// (后端不强制, 仅 UI 链接用)。
	DocAnchor string `json:"doc_anchor"`
	// HostingKinds 是该类型支持的托管机制列表 (L2 hosting_kind 候选)。
	// ADR-0022 v0.4: openclaw / hermes 同时支持 clawmanager / k8s_native; zap 仅
	// external_endpoint (协议接入已存在的服务)。
	HostingKinds []string `json:"hosting_kinds"`
}

// Service 暴露只读 list / validate。
type Service interface {
	List(ctx context.Context) []Type
	Validate(code string) bool
}

type impl struct{}

func New() Service { return &impl{} }

// known 是 4 层模型 L1 的固定列表; 改这里 = 改产品对外形状。
var known = []Type{
	{
		Code:         FrameworkOpenclaw,
		DisplayName:  "OpenClaw",
		Description:  "知办AI 自研 / 平台或租户托管的多 Agent 运行时, 支持 cron / 工作目录 / 多 Agent 调度。",
		DocAnchor:    "openclaw",
		HostingKinds: []string{"clawmanager", "k8s_native"},
	},
	{
		Code:         FrameworkHermes,
		DisplayName:  "Hermes",
		Description:  "兼容 ZAP v1 子集的传统 Agent 运行时; 仅支持单 Agent。",
		DocAnchor:    "hermes",
		HostingKinds: []string{"clawmanager", "k8s_native"},
	},
	{
		Code:         FrameworkZAP,
		DisplayName:  "自定义智能体平台（ZAP 协议）",
		Description:  "实现 ZAP v1.1 RuntimeCard + Agent Management 协议的第三方 / 自托管 Agent; 服务由对方提供, 平台仅按协议接入 (ADR-0022 §2.1)。",
		DocAnchor:    "zap",
		HostingKinds: []string{"external_endpoint"},
	},
	{
		Code:         FrameworkDSH,
		DisplayName:  "知办通用运行时（dsh）",
		Description:  "平台自营通用数字员工运行时（dsh 内核，ZAP 协议接入），数字员工默认执行器",
		DocAnchor:    "zap",
		HostingKinds: []string{"external_endpoint"},
	},
}

func (impl) List(_ context.Context) []Type {
	out := make([]Type, len(known))
	copy(out, known)
	return out
}

func (impl) Validate(code string) bool {
	for _, t := range known {
		if t.Code == code {
			return true
		}
	}
	return false
}

// HostingKindAllowed 检查 framework + hosting_kind 组合是否合法。
func HostingKindAllowed(framework, kind string) bool {
	for _, t := range known {
		if t.Code != framework {
			continue
		}
		for _, k := range t.HostingKinds {
			if k == kind {
				return true
			}
		}
		return false
	}
	return false
}

// IsZapWire 判定 framework 是否走 ZAP 线协议 (zap=外部自定义 Agent; dsh=平台自营运行时)。
// 派发/探测/注册等"协议层"分支用它; "平台策略"分支用 IsDSH。
func IsZapWire(framework string) bool {
	switch strings.ToLower(strings.TrimSpace(framework)) {
	case FrameworkZAP, FrameworkDSH:
		return true
	}
	return false
}

// IsDSH 判定是否平台自营 dsh 运行时。
func IsDSH(framework string) bool {
	return strings.EqualFold(strings.TrimSpace(framework), FrameworkDSH)
}
