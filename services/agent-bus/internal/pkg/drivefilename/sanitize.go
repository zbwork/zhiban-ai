// Package drivefilename 提供云盘文件名清洗工具。
//
// 由 F06 v0.3.1 §4.5 + ADR 0017 引用；移植自 ai-office legacy
// (internal/pkg/openclawdrive/filename.go)，沿用其完整规则集。
//
// 设计：
//   - 这是文件进入 drive 的「最后一道闸」：LLM / agent / 第三方 skill 都可能产出
//     `report <v2>|final?.docx` 这种带「Windows 禁用字符」的名字，直接入库会引发：
//   - Windows 客户端拉到云盘后无法另存为 (NTFS 拒绝 < > : " | ? * \ / 在文件名)
//   - markdown `[name](</data/.../<>.xlsx>)` 里的 `<` 会破坏 CommonMark <URL> 闭合
//   - URL 路径段里出现未编码 `?` `#` 会被解析成 query / fragment
//   - 行业一致做法 (Google Drive / Dropbox / OneDrive / 飞书 / 钉钉) 都是入库前替换
//     为 `_`，而不是返回错误 —— 文件名只是展示属性，语义不丢就行。
//   - 本 pkg 0 依赖 (仅 stdlib)，任何 layer 都可以 import；Phase 2.5 ZAP backchannel +
//     Phase 2.2 bus drive presign 入口会调。
package drivefilename

import (
	"path/filepath"
	"strings"
	"unicode"
)

// Sanitize 把可能含跨平台不友好字符的文件名清洗成在 Windows / macOS / Linux
// 都能正常落盘，并且在 markdown / URL 里不会破坏语法的形态。
//
// 替换规则：
//
//	< > : " | ? * \ /  → _    (Windows 禁用 9 字符 + 路径分隔符)
//	控制字符 / NUL      → 删除  (无意义且会被 shell / S3 SDK 拒)
//	首尾空格 / 点       → 删除  (Windows 会自动忽略 → 不一致)
//	连续多个 _         → 单个   (纯美观)
//	> 200 字节         → 截断，保留扩展名 (FAT/exFAT 上限 255，留 50 字节余量给后续 dedup _1/_2)
//	空字符串           → "untitled"
//
// **故意不动**的字符：中文 / emoji / 《》 / () / [] / , / ; / & / ' / 空格
// —— 这些在三大文件系统都合法，在 markdown <URL> 语法里也都允许 (URL 内只禁 < > \n)。
func Sanitize(raw string) string {
	if raw == "" {
		return "untitled"
	}

	var b strings.Builder
	b.Grow(len(raw))
	for _, r := range raw {
		switch {
		case r == 0:
			// NUL 任何系统都拒，直接吞掉。
		case unicode.IsControl(r):
			// 控制字符 (\n \r \t 等) 不留在文件名里。
		case r == '<' || r == '>' || r == '"' || r == '|' ||
			r == '?' || r == '*' || r == '\\' || r == '/' || r == ':':
			// Windows 禁用 9 字符 + 路径分隔符，统一替换 `_`。
			// `:` 也归这里 —— Windows NTFS 拒绝，且是 URL scheme 分隔符
			// (避免误造 claw-file: / sandbox: 之类协议头)。
			b.WriteByte('_')
		default:
			b.WriteRune(r)
		}
	}
	cleaned := b.String()

	// 连续多个 `_` 压成一个，避免 `<<<<.xlsx` → `____.xlsx` 这种丑名。
	for strings.Contains(cleaned, "__") {
		cleaned = strings.ReplaceAll(cleaned, "__", "_")
	}

	// 首尾「空格 / 点 / 下划线」整体 trim：
	//   - 末尾点是 Windows 自动 trim 的坑 (跟服务端一致性)
	//   - 首尾空格也是 Windows trim
	//   - 首尾 `_` 通常是禁用字符替换产生，trim 掉更美观
	cleaned = strings.TrimFunc(cleaned, func(r rune) bool {
		return r == ' ' || r == '.' || r == '_'
	})

	// trim 后空 / 只剩扩展名 (整名都被替换 + trim 干净)：回退 untitled + 原扩展。
	// 不能直接拿 cleaned 的扩展——cleaned 已经被 trim 没了。
	if cleaned == "" {
		ext := strings.ToLower(filepath.Ext(raw))
		if ext != "" && len(ext) <= 16 {
			return "untitled" + ext
		}
		return "untitled"
	}
	if !strings.ContainsRune(cleaned, '.') {
		// trim 后没有扩展名分隔符。可能是 raw 里扩展名前缀全是禁用字符
		// (例如 `<>|?.png` → 替换 `____.png` → 压缩 `_.png` → trim 后
		// 首部 `_` 没了变 `.png` → trim 末点 `png`)。这种情况补 untitled 前缀
		// 让扩展名仍然可见。
		ext := strings.ToLower(filepath.Ext(raw))
		if ext != "" && len(ext) <= 16 && strings.EqualFold("."+cleaned, ext) {
			return "untitled" + ext
		}
	}

	// 长度上限：FAT/exFAT 255 字节，留 50 字节余量给后续 dedup `_1`/`_2` 后缀。
	const maxLen = 200
	if len(cleaned) > maxLen {
		ext := filepath.Ext(cleaned)
		base := strings.TrimSuffix(cleaned, ext)
		// 留 `... + ext` 共 maxLen 字节。注意字节而非 rune ——
		// 截断中文可能切到半个 UTF-8 序列，所以 base 截断后再检查
		// UTF-8 边界。
		keep := maxLen - len(ext)
		if keep <= 0 {
			// 扩展名比上限还长——直接砍扩展名，保留 base 的 maxLen 字节。
			return safeTruncate(cleaned, maxLen)
		}
		cleaned = safeTruncate(base, keep) + ext
	}

	return cleaned
}

// safeTruncate 把字符串按字节截到 n 以内，不会把 UTF-8 序列切到一半。
//
// 从 n 往前找最近的 UTF-8 rune 起始字节 (高位为 0 或 11xxxxxx) 防止生成
// 非法 UTF-8 字节序列 (S3 SDK 会拒)。
func safeTruncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	// 从 n 往前找最近的 UTF-8 rune 起始字节。
	cut := n
	for cut > 0 && (s[cut]&0xC0) == 0x80 {
		cut--
	}
	return s[:cut]
}

// mimeExtensions 覆盖 agent 产出 artifact 最常见的几种 mime——不是完整的
// mime 数据库，只兜底"文件名没扩展名、但 mime 明确"的场景。stdlib
// `mime.ExtensionsByType` 依赖运行环境注册表，不同机器/容器结果可能不一致，
// 这里用固定表保证跨环境一致。
var mimeExtensions = map[string]string{
	"text/html":                ".html",
	"application/pdf":          ".pdf",
	"text/plain":               ".txt",
	"text/markdown":            ".md",
	"text/csv":                 ".csv",
	"application/json":         ".json",
	"application/zip":          ".zip",
	"image/png":                ".png",
	"image/jpeg":               ".jpg",
	"image/gif":                ".gif",
	"image/svg+xml":            ".svg",
	"application/msword":       ".doc",
	"application/vnd.ms-excel": ".xls",
	"application/vnd.openxmlformats-officedocument.wordprocessingml.document":   ".docx",
	"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":         ".xlsx",
	"application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
}

// EnsureExtension 补全下载文件名的扩展名。
//
// 背景 (2026-08-17 复现)：agent 产出的 artifact 有时只给一个友好展示名
// ("示例公司落地页")，没带扩展名——这个名字直接透传给 Content-Disposition，
// 用户下载下来的文件没有 .html 后缀，系统不知道用什么打开。
//
// name 本身已经带扩展名（不管是不是 mimeExtensions 认识的类型）就原样返回，
// 不覆盖调用方/用户自己选的扩展名；只有完全没扩展名、且 mimeType 能查到
// 对应扩展名时才追加。查不到就原样返回——不瞎猜。
func EnsureExtension(name, mimeType string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return trimmed
	}
	if filepath.Ext(trimmed) != "" {
		return trimmed
	}
	mt := strings.ToLower(strings.TrimSpace(mimeType))
	if idx := strings.IndexByte(mt, ';'); idx >= 0 {
		mt = strings.TrimSpace(mt[:idx]) // 去掉 "; charset=utf-8" 这类参数
	}
	ext, ok := mimeExtensions[mt]
	if !ok {
		return trimmed
	}
	return trimmed + ext
}
