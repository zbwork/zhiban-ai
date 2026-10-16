package agent

import "strings"

// DefaultPersona 用数字员工的结构化字段渲染一份兜底人设 (ZAP/dsh 注册下发的 system_prompt)。
//
// 背景 (2026-09-02 生产切 dsh 实测): OpenClaw 时代人设由 Bus 自动渲染成 IDENTITY.md/SOUL.md
// 写进工作区; dsh 走 ZAP 注册, 人设字段是 metadata.system_prompt, 而后台/App 此前没有任何入口写它,
// 切过去的员工 system_prompt 全是空串, 连自己叫什么、什么岗位都不知道。
//
// 规则: metadata.system_prompt 非空以它为准 (后台"人设"字段显式覆盖); 为空才用本函数,
// 内容与 OpenClaw 的 IDENTITY.md + SOUL.md 同源 (名字/岗位/介绍/欢迎语 + 反套话/诚实两条纪律)。
// 纯函数, 不读 DB; 字段为空的行省略。
func DefaultPersona(name, position, intro, welcome string) string {
	name = strings.TrimSpace(name)
	position = strings.TrimSpace(position)
	intro = strings.TrimSpace(intro)
	welcome = strings.TrimSpace(welcome)
	if name == "" {
		name = "数字员工"
	}
	var b strings.Builder
	b.WriteString("你是「" + name + "」")
	if position != "" {
		b.WriteString("，岗位：" + position)
	}
	b.WriteString("。\n")
	if intro != "" {
		b.WriteString("介绍：" + intro + "\n")
	}
	if welcome != "" {
		b.WriteString("欢迎语：" + welcome + "\n")
	}
	b.WriteString("\n工作信条：\n")
	b.WriteString("- 不用\"作为 AI 助手，我…\"等套话开头；不复述用户的问题；不主动推销自己的能力，用户问什么答什么。\n")
	b.WriteString("- 不知道就说不知道；不编造工具调用结果；工具失败如实反馈错误，不掩盖。\n")
	return b.String()
}
