package messageblocks

import (
	"fmt"
	"net/url"
	"strings"
)

// Attachment is the display metadata needed to persist chat file/image blocks.
type Attachment struct {
	UUID      string
	Name      string
	MimeType  string
	SizeBytes int64
}

// AppendAttachments appends EMP image/file blocks for attachments not already
// represented in blocks. CMF remains the authorization/runtime data source;
// these blocks are the history display source.
func AppendAttachments(blocks []map[string]any, files []Attachment) []map[string]any {
	if len(files) == 0 {
		return blocks
	}
	seen := make(map[string]struct{}, len(blocks)+len(files))
	for _, b := range blocks {
		if id := attachmentIDFromBlock(b); id != "" {
			seen[id] = struct{}{}
		}
	}
	out := blocks
	for _, f := range files {
		uuid := strings.TrimSpace(f.UUID)
		if uuid == "" {
			continue
		}
		if _, ok := seen[uuid]; ok {
			continue
		}
		seen[uuid] = struct{}{}
		out = append(out, AttachmentBlock(Attachment{
			UUID:      uuid,
			Name:      f.Name,
			MimeType:  f.MimeType,
			SizeBytes: f.SizeBytes,
		}))
	}
	return out
}

// AttachmentBlock builds the canonical block shape consumed by zhiban-app
// history hydration.
func AttachmentBlock(f Attachment) map[string]any {
	kind := "file"
	primaryAction := "download"
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(f.MimeType)), "image/") {
		kind = "image"
		primaryAction = "preview"
	}
	escaped := url.PathEscape(strings.TrimSpace(f.UUID))
	previewURL := fmt.Sprintf("/message-files/%s/preview", escaped)
	downloadURL := fmt.Sprintf("/message-files/%s/download", escaped)
	primaryURL := downloadURL
	if primaryAction == "preview" {
		primaryURL = previewURL
	}
	return map[string]any{
		"type":         kind,
		"file_id":      strings.TrimSpace(f.UUID),
		"name":         f.Name,
		"mime":         f.MimeType,
		"size":         f.SizeBytes,
		"url":          primaryURL,
		"preview_url":  previewURL,
		"download_url": downloadURL,
	}
}

func attachmentIDFromBlock(block map[string]any) string {
	if len(block) == 0 {
		return ""
	}
	if v, ok := block["file_id"]; ok {
		if s := strings.TrimSpace(fmt.Sprint(v)); s != "" && s != "<nil>" {
			return s
		}
	}
	return ""
}
