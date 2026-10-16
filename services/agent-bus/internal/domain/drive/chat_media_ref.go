package drive

import "time"

// ChatMediaRef P2.2c:聊天文件消息的会话级媒体引用(与 PG message 解耦)。
//
// 授权单元:绑定 conversation/room,快照 storage_key;preview/download 由 service 按
// room_participants 活跃 human 成员鉴权后现签短 TTL → 302。源 drive 文件 ACL 不受影响。
type ChatMediaRef struct {
	ID              int64
	UUID            string
	TenantID        int64
	ConversationID  int64
	RoomID          *int64
	SenderAccountID int64
	MediaKind       int    // 2=image, 8=file (与 WuKong content type 对齐)
	SourceKind      string // chat_upload | drive
	DriveFileUUID   string
	StorageKey      string
	FileName        string
	MimeType        string
	SizeBytes       int64
	CreatedAt       time.Time
}

// 媒体类型常量(与客户端 WkMessageContentType / WuKong 对齐)。
const (
	ChatMediaKindImage = 2
	ChatMediaKindFile  = 8
)

// 来源常量。
const (
	ChatMediaSourceUpload = "chat_upload"
	ChatMediaSourceDrive  = "drive"
)

// CreateChatMediaRefInput 建 ref 入参。
type CreateChatMediaRefInput struct {
	TenantID        int64
	ConversationID  int64
	RoomID          *int64
	SenderAccountID int64
	MediaKind       int
	SourceKind      string
	DriveFileUUID   string
	StorageKey      string
	FileName        string
	MimeType        string
	SizeBytes       int64
}
