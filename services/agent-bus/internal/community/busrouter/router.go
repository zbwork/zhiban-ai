package busrouter

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcatalog"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientchat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcontacts"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientcron"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientdrive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/session"
	"net/http"
)

type Handlers struct {
	Catalog   *clientcatalog.Handlers
	Agents    *clientcatalog.AgentHandlers
	Cron      *clientcron.Handlers
	Knowledge *clientcatalog.KnowledgeHandler
	Chat      *clientchat.Handlers
	Session   *session.Handlers
	Contacts  *clientcontacts.Handlers
	Drive     *clientdrive.Handlers
}

func (h Handlers) Register(mux *http.ServeMux, auth func(http.Handler) http.Handler, membership middleware.TenantMembershipReader) {
	if auth == nil || membership == nil || h.Session == nil || h.Contacts == nil {
		panic("community Bus dependencies required")
	}
	authT := func(handler http.Handler) http.Handler {
		return auth(middleware.RequireTenant(middleware.RequireActiveTenantMembership(membership)(handler)))
	}
	if h.Agents != nil {
		mux.Handle("GET /api/agent-bus/v1/agents", authT(http.HandlerFunc(h.Agents.List)))
		mux.Handle("GET /api/agent-bus/v1/agents/{uuid}", authT(http.HandlerFunc(h.Agents.Get)))
	}
	if h.Catalog != nil {
		mux.Handle("GET /api/agent-bus/v1/skills", authT(http.HandlerFunc(h.Catalog.Skills)))
		mux.Handle("GET /api/agent-bus/v1/skill-categories", authT(http.HandlerFunc(h.Catalog.Categories)))
	}
	if h.Cron != nil {
		mux.Handle("GET /api/agent-bus/v1/cron/jobs", authT(http.HandlerFunc(h.Cron.ListJobs)))
		mux.Handle("GET /api/agent-bus/v1/cron/runs", authT(http.HandlerFunc(h.Cron.ListRuns)))
	}
	if h.Knowledge != nil {
		mux.Handle("GET /api/agent-bus/v1/knowledge-bases", authT(http.HandlerFunc(h.Knowledge.List)))
	}
	mux.HandleFunc("GET  /api/agent-bus/v1/auth/captcha", h.Session.Captcha)
	mux.HandleFunc("POST /api/agent-bus/v1/auth/login/password", h.Session.LoginPassword)
	mux.HandleFunc("POST /api/agent-bus/v1/auth/token/refresh", h.Session.Refresh)
	mux.Handle("POST /api/agent-bus/v1/auth/logout", authT(http.HandlerFunc(h.Session.Logout)))
	mux.Handle("GET  /api/agent-bus/v1/auth/me", auth(http.HandlerFunc(h.Session.Me)))
	mux.Handle("POST /api/agent-bus/v1/auth/scope/switch", auth(http.HandlerFunc(h.Session.SwitchScope)))
	mux.Handle("GET  /api/agent-bus/v1/auth/menu", authT(http.HandlerFunc(h.Session.Menu)))
	mux.Handle("POST /api/agent-bus/v1/auth/password/change", authT(http.HandlerFunc(h.Session.ChangePassword)))
	mux.Handle("GET  /api/agent-bus/v1/contacts/tree", authT(http.HandlerFunc(h.Contacts.ContactsTree)))
	mux.Handle("GET  /api/agent-bus/v1/contacts", authT(http.HandlerFunc(h.Contacts.ContactsList)))
	mux.Handle("GET  /api/agent-bus/v1/contacts/agents", authT(http.HandlerFunc(h.Contacts.ContactsAgents)))
	mux.Handle("GET  /api/agent-bus/v1/contacts/recent", authT(http.HandlerFunc(h.Contacts.ContactsRecent)))
	mux.Handle("POST /api/agent-bus/v1/contacts/search", authT(http.HandlerFunc(h.Contacts.ContactsSearch)))
	mux.Handle("GET  /api/agent-bus/v1/contacts/members/{account_uuid}", authT(http.HandlerFunc(h.Contacts.ContactsMember)))
	mux.Handle("GET  /api/agent-bus/v1/contacts/agents/{agent_uuid}", authT(http.HandlerFunc(h.Contacts.ContactsAgent)))
	mux.Handle("GET  /api/agent-bus/v1/contacts/policy", authT(http.HandlerFunc(h.Contacts.ContactsPolicy)))
	mux.Handle("POST /api/agent-bus/v1/contacts/can-create-group", authT(http.HandlerFunc(h.Contacts.ContactsCanCreateGroup)))

	if h.Drive != nil {
		mux.Handle("POST   /api/agent-bus/v1/drive:bootstrap", authT(http.HandlerFunc(h.Drive.DriveV3Bootstrap)))
		mux.Handle("GET    /api/agent-bus/v1/drive/spaces/{uuid}/folders/tree", authT(http.HandlerFunc(h.Drive.DriveV3FolderTree)))
		mux.Handle("GET    /api/agent-bus/v1/drive/folders/{uuid}/children", authT(http.HandlerFunc(h.Drive.DriveV3FolderChildren)))
		mux.Handle("POST   /api/agent-bus/v1/drive/folders", authT(http.HandlerFunc(h.Drive.DriveV3FolderCreate)))
		mux.Handle("PATCH  /api/agent-bus/v1/drive/folders/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FolderRename)))
		mux.Handle("POST   /api/agent-bus/v1/drive/folders/{uuid}/move", authT(http.HandlerFunc(h.Drive.DriveV3FolderMove)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/folders/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FolderDelete)))
		mux.Handle("POST /api/agent-bus/v1/drive/files:upload", authT(http.HandlerFunc(h.Drive.DriveV3FilesUpload)))
		mux.Handle("POST /api/agent-bus/v1/drive/files:presign-put", authT(http.HandlerFunc(h.Drive.DriveV3FilesPresignPut)))
		mux.Handle("POST /api/agent-bus/v1/drive/files:complete-multipart", authT(http.HandlerFunc(h.Drive.DriveV3FilesCompleteMultipart)))
		mux.Handle("POST /api/agent-bus/v1/drive/files:refresh-part-urls", authT(http.HandlerFunc(h.Drive.DriveV3FilesRefreshPartURLs)))
		mux.Handle("POST /api/agent-bus/v1/drive/files:confirm", authT(http.HandlerFunc(h.Drive.DriveV3FilesConfirm)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FileGet)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files/{uuid}/preview", authT(http.HandlerFunc(h.Drive.DriveV3FilePreview)))
		mux.Handle("PATCH  /api/agent-bus/v1/drive/files/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FileRename)))
		mux.Handle("POST   /api/agent-bus/v1/drive/files/{uuid}/move", authT(http.HandlerFunc(h.Drive.DriveV3FileMove)))
		mux.Handle("POST   /api/agent-bus/v1/drive/files/{uuid}/retry-copy", authT(http.HandlerFunc(h.Drive.DriveV3FileRetryCopy)))
		mux.Handle("POST   /api/agent-bus/v1/drive/files/{uuid}/cancel-copy", authT(http.HandlerFunc(h.Drive.DriveV3FileCancelCopy)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files/{uuid}/versions", authT(http.HandlerFunc(h.Drive.DriveV3FileListVersions)))
		mux.Handle("POST   /api/agent-bus/v1/drive/files/{uuid}/versions/{version_no}/restore", authT(http.HandlerFunc(h.Drive.DriveV3FileRestoreVersion)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/files/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FileDelete)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files:recent", authT(http.HandlerFunc(h.Drive.DriveV3FilesRecent)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files:search", authT(http.HandlerFunc(h.Drive.DriveV3FilesSearch)))
		mux.Handle("GET    /api/agent-bus/v1/drive/favorites", authT(http.HandlerFunc(h.Drive.DriveFavoritesList)))
		mux.Handle("PUT    /api/agent-bus/v1/drive/favorites/{target_kind}/{target_uuid}", authT(http.HandlerFunc(h.Drive.DriveFavoriteAdd)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/favorites/{target_kind}/{target_uuid}", authT(http.HandlerFunc(h.Drive.DriveFavoriteRemove)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files", authT(http.HandlerFunc(h.Drive.DriveV3FilesList)))
		mux.Handle("GET    /api/agent-bus/v1/drive/files/{uuid}/download", authT(http.HandlerFunc(h.Drive.DriveV3FileDownload)))
		mux.Handle("GET    /api/agent-bus/v1/drive/recycle", authT(http.HandlerFunc(h.Drive.DriveV3RecycleList)))
		mux.Handle("GET    /api/agent-bus/v1/drive/recycle/{uuid}/preview", authT(http.HandlerFunc(h.Drive.DriveV3RecyclePreview)))
		mux.Handle("POST   /api/agent-bus/v1/drive/recycle/{uuid}/restore", authT(http.HandlerFunc(h.Drive.DriveV3RecycleRestore)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/recycle/{uuid}/purge", authT(http.HandlerFunc(h.Drive.DriveV3RecyclePurge)))
		mux.Handle("POST   /api/agent-bus/v1/drive/shared-spaces", authT(http.HandlerFunc(h.Drive.DriveV3SharedSpaceCreate)))
		mux.Handle("GET    /api/agent-bus/v1/drive/shared-spaces", authT(http.HandlerFunc(h.Drive.DriveV3SharedSpaceList)))
		mux.Handle("PATCH  /api/agent-bus/v1/drive/shared-spaces/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3SharedSpaceUpdate)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/shared-spaces/{uuid}", authT(http.HandlerFunc(h.Drive.DriveV3SharedSpaceArchive)))
		mux.Handle("POST   /api/agent-bus/v1/drive/spaces/{uuid}/members", authT(http.HandlerFunc(h.Drive.DriveV3SpaceMemberAdd)))
		mux.Handle("GET    /api/agent-bus/v1/drive/spaces/{uuid}/members", authT(http.HandlerFunc(h.Drive.DriveV3SpaceMemberList)))
		mux.Handle("PATCH  /api/agent-bus/v1/drive/spaces/{uuid}/members/{account_uuid}", authT(http.HandlerFunc(h.Drive.DriveV3SpaceMemberUpdate)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/spaces/{uuid}/members/{account_uuid}", authT(http.HandlerFunc(h.Drive.DriveV3SpaceMemberRemove)))
		mux.Handle("POST   /api/agent-bus/v1/drive/folders/{uuid}/members", authT(http.HandlerFunc(h.Drive.DriveV3FolderMemberAdd)))
		mux.Handle("GET    /api/agent-bus/v1/drive/folders/{uuid}/members", authT(http.HandlerFunc(h.Drive.DriveV3FolderMemberList)))
		mux.Handle("PATCH  /api/agent-bus/v1/drive/folders/{uuid}/members/{account_uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FolderMemberUpdate)))
		mux.Handle("DELETE /api/agent-bus/v1/drive/folders/{uuid}/members/{account_uuid}", authT(http.HandlerFunc(h.Drive.DriveV3FolderMemberRemove)))
	}

	if h.Chat != nil {
		mux.Handle("POST /api/agent-bus/v1/chat/send", authT(http.HandlerFunc(h.Chat.Send)))
		mux.Handle("GET /api/agent-bus/v1/chat/stream", authT(http.HandlerFunc(h.Chat.Stream)))
		mux.Handle("POST /api/agent-bus/v1/messages/{uuid}/stop", authT(http.HandlerFunc(h.Chat.Stop)))
		mux.Handle("POST /api/agent-bus/v1/messages/{uuid}/retry", authT(http.HandlerFunc(h.Chat.Retry)))
		mux.Handle("GET /api/agent-bus/v1/chat/conversations/{uuid}/messages", authT(http.HandlerFunc(h.Chat.History)))
	}
}
