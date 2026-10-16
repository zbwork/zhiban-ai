// Package diagnostics keeps the most recent failure per target so
// diagnostics.get_latest can show an error code, its stage and local
// remediation hints without paths, tokens or output. The App starts a fresh
// Bridge process for every action, so the record must outlive the process
// that produced it: a persistent recorder mirrors the map into a small JSON
// file under the Bridge state directory (target id, kind, stage, error code,
// timestamp and redacted verification/native-install failure details —
// no paths, tokens or raw tool output). Until 11914 the recorder was
// memory-only, which made "诊断详情" empty for every failure the user opened
// it for.
package diagnostics

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	KindInstall = "install"
	KindVerify  = "verify"
	KindConfig  = "config"
	KindLaunch  = "launch"
	KindDetect  = "detect"
)

var errorCodePattern = regexp.MustCompile(`^LCT-[A-Z_]+-[A-Z]+-[A-Z_]+$`)

// Latest is the diagnostics.get_latest result.
type Latest struct {
	TargetID      string  `json:"target_id"`
	BridgeVersion string  `json:"bridge_version"`
	OccurredAt    *string `json:"occurred_at"`
	Kind          *string `json:"kind"`
	Stage         *string `json:"stage"`
	ErrorCode     *string `json:"error_code"`
	// ErrorDetail is the operation envelope's sanitized error_detail.
	ErrorDetail *string  `json:"error_detail,omitempty"`
	Suggestions []string `json:"suggestions"`
}

type record struct {
	kind       string
	stage      string
	errorCode  string
	detail     string
	occurredAt time.Time
}

// Recorder is safe for concurrent use.
type Recorder struct {
	bridgeVersion string
	now           func() time.Time
	// path is the JSON file the records are mirrored into; empty keeps the
	// recorder memory-only (tests).
	path string

	mu     sync.Mutex
	latest map[string]record
}

// NewRecorder creates an empty, memory-only recorder.
func NewRecorder(bridgeVersion string, now func() time.Time) *Recorder {
	if now == nil {
		now = time.Now
	}
	return &Recorder{bridgeVersion: bridgeVersion, now: now, latest: make(map[string]record)}
}

// NewPersistentRecorder creates a recorder backed by the JSON file at path:
// existing records are loaded (a missing or unreadable file starts empty) and
// every Record rewrites the file atomically with mode 0600.
func NewPersistentRecorder(bridgeVersion string, now func() time.Time, path string) *Recorder {
	recorder := NewRecorder(bridgeVersion, now)
	recorder.path = filepath.Clean(path)
	recorder.load()
	return recorder
}

// DefaultPath is where the Bridge keeps its diagnostics file.
func DefaultPath(homeDir string) string {
	return filepath.Join(homeDir, "Library", "Application Support", "cn.qkfintech.zhiban", "local-coding-tools", "state", "diagnostics.json")
}

const storeSchemaVersion = 1

type storedRecord struct {
	Kind       string    `json:"kind"`
	Stage      string    `json:"stage"`
	ErrorCode  string    `json:"error_code"`
	Detail     string    `json:"detail,omitempty"`
	OccurredAt time.Time `json:"occurred_at"`
}

type store struct {
	Schema  int                     `json:"schema"`
	Records map[string]storedRecord `json:"records"`
}

func (r *Recorder) load() {
	if r.path == "" {
		return
	}
	content, err := os.ReadFile(r.path)
	if err != nil || len(content) > 64<<10 {
		return
	}
	var data store
	if json.Unmarshal(content, &data) != nil || data.Schema != storeSchemaVersion {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for targetID, item := range data.Records {
		if targetID == "" || !errorCodePattern.MatchString(item.ErrorCode) || item.OccurredAt.IsZero() {
			continue
		}
		r.latest[targetID] = record{kind: item.Kind, stage: item.Stage, errorCode: item.ErrorCode, detail: boundedDetail(item.Detail), occurredAt: item.OccurredAt.UTC()}
	}
}

// saveLocked mirrors the map to disk; callers hold r.mu. Failures are
// swallowed: diagnostics must never break the operation that produced them.
func (r *Recorder) saveLocked() {
	if r.path == "" {
		return
	}
	data := store{Schema: storeSchemaVersion, Records: make(map[string]storedRecord, len(r.latest))}
	for targetID, item := range r.latest {
		data.Records[targetID] = storedRecord{Kind: item.kind, Stage: item.stage, ErrorCode: item.errorCode, Detail: item.detail, OccurredAt: item.occurredAt}
	}
	content, err := json.Marshal(data)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		return
	}
	temporary, err := os.CreateTemp(filepath.Dir(r.path), ".diagnostics-*.json")
	if err != nil {
		return
	}
	name := temporary.Name()
	_, writeErr := temporary.Write(content)
	closeErr := temporary.Close()
	if writeErr != nil || closeErr != nil || os.Chmod(name, 0o600) != nil || os.Rename(name, r.path) != nil {
		_ = os.Remove(name)
	}
}

// Record stores a failure. Empty or malformed codes are ignored so callers
// can pass through whatever a lower layer produced.
func (r *Recorder) Record(targetID, kind, stage, errorCode string) {
	r.RecordDetail(targetID, kind, stage, errorCode, "")
}

// RecordDetail is Record with the operation's error_detail.
func (r *Recorder) RecordDetail(targetID, kind, stage, errorCode, detail string) {
	if targetID == "" || !errorCodePattern.MatchString(errorCode) {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.latest[targetID] = record{kind: kind, stage: stage, errorCode: errorCode, detail: boundedDetail(detail), occurredAt: r.now().UTC()}
	r.saveLocked()
}

// maxDetailBytes matches operation's bound on error_detail.
const maxDetailBytes = 1024

func boundedDetail(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > maxDetailBytes || !utf8.ValidString(value) {
		return ""
	}
	return value
}

// Path returns the backing file, or "" for a memory-only recorder.
func (r *Recorder) Path() string { return r.path }

// Clear forgets the record for targetID: a later success means the latest
// event for that target is no longer a problem, so 诊断详情 must not keep
// showing a stale failure (11916 test Mac: the component was provisioned but
// the earlier PUBLISHER_MISMATCH stayed on file).
func (r *Recorder) Clear(targetID string) {
	if targetID == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.latest[targetID]; !ok {
		return
	}
	delete(r.latest, targetID)
	r.saveLocked()
}

// Observe is the operation registry observer: failed and cancelled operations
// become diagnostics records; a succeeded operation clears the target's record.
func (r *Recorder) Observe(event operation.Event) {
	envelope := event.Envelope
	if envelope.State == operation.StateSucceeded {
		r.Clear(envelope.TargetID)
		return
	}
	if (envelope.State != operation.StateFailed && envelope.State != operation.StateCancelled) || envelope.ErrorCode == nil {
		return
	}
	detail := ""
	if envelope.ErrorDetail != nil {
		detail = *envelope.ErrorDetail
	}
	r.RecordDetail(envelope.TargetID, envelope.Kind, envelope.Stage, *envelope.ErrorCode, detail)
}

// Latest returns the most recent record for targetID, or an empty result.
func (r *Recorder) Latest(targetID string) Latest {
	result := Latest{TargetID: targetID, BridgeVersion: r.bridgeVersion, Suggestions: []string{}}
	r.mu.Lock()
	item, ok := r.latest[targetID]
	r.mu.Unlock()
	if !ok {
		return result
	}
	occurredAt := item.occurredAt.Format(time.RFC3339)
	kind := item.kind
	stage := item.stage
	code := item.errorCode
	if item.detail != "" {
		detail := item.detail
		result.ErrorDetail = &detail
	}
	result.OccurredAt = &occurredAt
	result.Kind = &kind
	result.Stage = &stage
	result.ErrorCode = &code
	result.Suggestions = Suggestions(code)
	return result
}

// Suggestions maps a contract error code to local, user-facing next steps.
func Suggestions(errorCode string) []string {
	parts := strings.Split(errorCode, "-")
	if len(parts) != 4 {
		return []string{"重试", "上传详细诊断并联系支持"}
	}
	switch parts[2] + "-" + parts[3] {
	case "INSTALL-DOWNLOAD_FAILED":
		return []string{"检查网络后重试", "稍后重新下载安装"}
	case "INSTALL-PUBLISHER_MISMATCH":
		return []string{"查看失败详情，确认是解压、签名还是系统安全检查失败", "重新下载安装；仍失败时发送诊断给支持"}
	case "INSTALL-HASH_MISMATCH", "INSTALL-SIZE_MISMATCH":
		return []string{"重新下载安装", "检查网络是否经过代理或被劫持"}
	case "INSTALL-SOURCE_NOT_ALLOWED":
		return []string{"下载地址不是 https 或主机不在允许列表，不是签名问题", "联系管理员核对版本目录的下载地址与 allowed_hosts"}
	case "INSTALL-SYSTEM_CANCELLED", "LAUNCH-SYSTEM_CANCELLED":
		return []string{"重新开始该操作"}
	case "INSTALL-AUTHORIZATION_CANCELLED", "INSTALL-AUTHORIZATION_TIMEOUT":
		return []string{"尚未下载安装；重新点击安装，在 Windows 系统授权提示中选择“是”"}
	case "INSTALL-AUTHORIZATION_FAILED":
		return []string{"系统管理员授权未能启动，尚未下载安装", "重试或联系管理员核对系统策略"}
	case "INSTALL-REGISTRATION_FAILED":
		return []string{"Windows 未能完成应用注册，不代表设置文件发生冲突", "发送诊断给支持，按失败时间核对 Windows 应用部署记录"}
	case "INSTALL-COMPONENT_IN_USE":
		return []string{"运行组件文件仍被其他进程占用，已等待后重试", "稍后再试；持续失败时发送诊断给支持"}
	case "INSTALL-CONFLICT":
		return []string{"检查本机已有的同名安装或软链接", "移除冲突文件后重试"}
	case "INSTALL-DETECT_MISMATCH":
		return []string{"重新检测", "上传详细诊断并联系支持"}
	case "INSTALL-RUNNING_CHECK_FAILED":
		// 不是"正在运行"：是知办没能确认它有没有在运行（枚举进程超时或被安全软件拦）。
		return []string{"知办没能确认这个应用是否正在运行，不是发现了占用", "稍后重试；反复出现请上传详细诊断并联系支持"}
	case "INSTALL-ALREADY_INSTALLED", "INSTALL-NOT_REPAIRABLE":
		return []string{"重新检测"}
	case "INSTALL-REQUIREMENTS_UNMET", "INSTALL-UNSUPPORTED_ARCH":
		return []string{"查看系统要求", "释放磁盘空间或更换设备后重试"}
	case "OPERATION-BUSY":
		return []string{"等待当前操作完成"}
	case "AUTH-DEVICE_MISSING", "AUTH-DEVICE_REVOKED":
		// 用户多半仍在登录状态(授权是退出登录 / 切环境 / 重装时丢的),别让人去重新登录。
		return []string{"点「一键修复」重新接入设备授权"}
	case "AUTH-INSUFFICIENT_CREDIT":
		// 设备授权是好的，重新接入没用（2026-09-20 生产：欠费用户被提示"一键修复"，越点越糊涂）。
		return []string{"积分已用完，知办暂停了本地开发工具的模型服务", "在知办「设置 → 套餐与积分」充值（成员请联系企业管理员），到账后点「重新检测」即可恢复，不需要重新接入"}
	case "AUTH-MEMBER_KEY_DISABLED":
		return []string{"你的模型服务已被停用，设备授权本身没有问题，重新接入没用", "请联系企业管理员确认成员状态，恢复后点「重新检测」"}
	case "AUTH-TOKEN_EXPIRED":
		return []string{"重新启动并完成验证", "必要时重新登录知办"}
	case "AUTH-SCOPE_DENIED":
		return []string{"联系管理员开通对应权益"}
	case "GATEWAY-PROXY_INTERFERENCE":
		return []string{"点「一键修复」为知办中转站设置代理例外", "重开 Codex 桌面端，终端请新开窗口"}
	case "GATEWAY-PROXY_DIVERTED":
		// 知办不替用户关代理、不改代理软件的配置：TUN 下只有代理软件自己的规则管用。
		return []string{
			"工具请求知办中转站失败，可能受代理软件分流影响（知办自己的直连探测成功，但不证明工具的代理线路一定失败）",
			"在代理软件里把 airick.cn 设为直连，规则行：DOMAIN-SUFFIX,airick.cn,DIRECT（要排在按进程名分流的规则之前）",
			"或暂时关闭代理软件的 TUN / 增强模式（全局模式请切回规则模式），再点「重新检测」",
		}
	case "GATEWAY-UNREACHABLE":
		return []string{"检查网络后重试"}
	case "GATEWAY-UPSTREAM_UNAVAILABLE":
		return []string{"知办中转站暂时不可用，不是本机问题，稍后点「重新检测」", "持续出现请把「中转站返回」内容发给支持"}
	case "GATEWAY-MODEL_DENIED":
		// 多半是用户在工具里选了自己分组没开放的模型（2026-09-17 真机）。
		return []string{"在工具里换一个模型再试", "仍不行请把「中转站返回」内容发给支持"}
	case "GATEWAY-QUOTA_EXHAUSTED":
		return []string{"检查权益余量", "稍后重试"}
	case "GATEWAY-PROTOCOL_MISMATCH":
		return []string{"重试", "上传详细诊断并联系支持"}
	case "LAUNCH-PROCESS_FAILED":
		return []string{"重新检测", "重新安装工具"}
	case "LAUNCH-PROJECT_PERMISSION_DENIED":
		return []string{"重新选择项目目录"}
	case "CONFIG-CONFLICT":
		return []string{"确认是否手动改过知办隔离配置", "移除知办接入后重新接入"}
	case "VERIFY-NOT_CONFIGURED":
		return []string{"先执行一键接入知办"}
	case "VERIFY-INSTALLATION_CHANGED":
		return []string{"重新检测后再验证"}
	case "DETECT-MULTIPLE_INSTALLS":
		return []string{"只保留一个安装来源后重新检测"}
	case "DETECT-DAMAGED", "DETECT-TIMEOUT":
		return []string{"一键修复", "重新安装工具"}
	case "DETECT-VERSION_UNKNOWN":
		return []string{"安装受支持的版本"}
	case "DETECT-UNTRUSTED_PATH":
		return []string{"检查 PATH 中该可执行文件的来源"}
	default:
		return []string{"重试", "上传详细诊断并联系支持"}
	}
}
