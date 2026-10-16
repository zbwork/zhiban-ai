package chat

import "strings"

const ErrCodeOpenClawInputPrepareFailed = "chat.openclaw_input_prepare_failed"
const ErrCodeRuntimeInputPrepareFailed = "chat.runtime_input_prepare_failed"

func promptTextWithOpenClawInputs(prompt string, inputs []OpenClawPreparedInput) string {
	return promptTextWithRuntimeInputs(prompt, inputs, "OpenClaw workspace")
}

func promptTextWithHermesInputs(prompt string, inputs []OpenClawPreparedInput) string {
	return promptTextWithRuntimeInputs(prompt, inputs, "Hermes workspace")
}

func promptTextWithRuntimeInputs(prompt string, inputs []OpenClawPreparedInput, workspaceLabel string) string {
	if len(inputs) == 0 {
		return prompt
	}
	var b strings.Builder
	b.WriteString(prompt)
	if strings.TrimSpace(prompt) != "" {
		b.WriteString("\n\n")
	}
	if strings.TrimSpace(workspaceLabel) == "" {
		workspaceLabel = "runtime workspace"
	}
	b.WriteString("本轮用户上传的文件已准备到 ")
	b.WriteString(workspaceLabel)
	b.WriteString(" 的 inputs 目录。请优先使用下列本地路径读取文件内容，不要只按文件名搜索：\n")
	for _, in := range inputs {
		name := strings.TrimSpace(in.Name)
		path := strings.TrimSpace(in.Path)
		if path == "" {
			continue
		}
		if name == "" {
			name = path
		}
		b.WriteString("- ")
		b.WriteString(name)
		b.WriteString(": ")
		b.WriteString(path)
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}
