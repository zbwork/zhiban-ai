package beebridge

import "strings"

// Model retains capabilities from the member-key catalogue without credentials.
type Model struct {
	ID                     string   `json:"id"`
	SupportedEndpointTypes []string `json:"supported_endpoint_types"`
}

// ChatProtocol selects the wire protocol for a managed BeeBridge model.
// Custom providers must keep their configured protocol. Preserve the original
// model ID on the wire; a provider prefix is ignored only for family detection.
func ChatProtocol(modelID string) string {
	name := strings.ToLower(strings.TrimSpace(modelID))
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	if name == "claude" || strings.HasPrefix(name, "claude-") {
		return "anthropic-messages"
	}
	return "openai-compatible"
}

// SupportsChat excludes dedicated review models and known non-chat capabilities.
// The upstream catalogue can omit capabilities or label embeddings as generic
// "openai", so known model families supplement metadata. Unknown names remain
// compatible, not certified.
func (m Model) SupportsChat() bool {
	if strings.TrimSpace(m.ID) == "" {
		return false
	}
	// Review-only models must not enter conversation choices, even when the
	// upstream advertises generic chat endpoints. Keep ordinary code models.
	modelName := strings.ToLower(strings.TrimSpace(m.ID))
	if i := strings.LastIndexByte(modelName, '/'); i >= 0 {
		modelName = modelName[i+1:]
	}
	switch modelName {
	case "codex-auto-review", "code-auto-review":
		return false
	}
	for _, endpoint := range m.SupportedEndpointTypes {
		switch strings.ToLower(strings.TrimSpace(endpoint)) {
		case "embedding", "embeddings", "rerank", "reranker", "reranking",
			"image", "images", "image-generation", "images/generations",
			"audio", "audio/speech", "audio/transcriptions", "audio/translations",
			"tts", "stt", "video", "videos", "moderation", "moderations":
			return false
		}
	}
	// Name-segment fallback for catalogue entries whose capabilities are missing or
	// mislabelled. supported_endpoint_types above stays authoritative; this only
	// catches what upstream failed to describe.
	//
	// 2026-09-12: gemini-3.1-flash-image reached the chat menu because BeeBridge
	// returned no image endpoint type for it, while gpt-image-* were labelled and
	// filtered correctly. Media segments therefore have to be covered here too.
	//
	// Match name segments, not arbitrary substrings (e.g. "my-embedding-helper"
	// denotes an embedding family, but "myembedded-chat" does not).
	name := strings.ToLower(m.ID)
	for _, part := range strings.FieldsFunc(name, func(r rune) bool {
		return r == '/' || r == ':' || r == '-' || r == '_' || r == '.'
	}) {
		switch part {
		case "bge", "embedding", "embeddings", "embed", "rerank", "reranker", "whisper", "tts", "moderation",
			// Media generation families. "vision" is deliberately absent: a
			// vision-capable chat model still chats.
			"image", "images", "img", "video", "videos", "audio", "speech", "voice", "diffusion", "dalle", "sora":
			return false
		}
	}
	return true
}
