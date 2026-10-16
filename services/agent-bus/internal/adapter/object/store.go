// Package object 是对象存储的窄接口 (Batch 3C T3.7 / T3.8).
//
// 设计目标:
//
//  1. chat 附件 presign 路径只依赖 Store.PresignPut(ctx, key, ttl, mime) → URL;
//     不锁定 S3 / MinIO / OSS / 自建存储, 任一后端只要实现 Store 即可.
//  2. download / preview 走 Store.PresignGet(ctx, key, ttl, inline) → URL,
//     transport 直接 302 重定向, 不走 bus 进程过流量.
//  3. 调试 / 集成测试 / smoke 可使用 inmem 实现 (sub-package), 把对象 PUT/GET 收到
//     bus 进程自己的 /_object/* endpoint, 不依赖外部基础设施.
//
// 与 DB 列的关系:
//   - message_files.storage_kind 记后端类型 (s3/oss/minio/inmem)
//   - message_files.storage_key 记 Store 看到的 key (bucket-relative path)
//   - bind 路径不读 storage_key (只动 state / message_uuid), 故对象存储侧任何变更
//     不影响 message_files 表事务
package object

import (
	"context"
	"errors"
	"time"
)

// PresignPutInput presign PUT 入参.
type PresignPutInput struct {
	// Key 是 store 内的唯一路径 (不带 scheme/host); 由 service 层用
	// "tenant/<tid>/account/<aid>/<yyyy>/<mm>/<uuid>/<filename>" 拼成.
	Key string
	// ContentType 期望客户端 PUT 时填的 Content-Type; store 可能把它放到 query
	// (S3 presigned URL) 或者要求 client header 严格匹配 (MinIO virtual hosted).
	ContentType string
	// ContentLength 期望的字节数; 0 视为未知. store 实现可据此加上 Content-Length-Range 条件.
	ContentLength int64
	// TTL 过期时长; service 层传 ≤ 5min (与 docs/modules/m4 §4.3 一致).
	TTL time.Duration
}

// PresignPutOutput presign PUT 出参.
type PresignPutOutput struct {
	// URL 客户端 PUT 目标; 含签名 query / 路径.
	URL string
	// Headers 客户端 PUT 时**必须**带的 header (e.g. Content-Type). map 顺序无关.
	// 空 map 表示无要求.
	Headers map[string]string
	// ExpiresAt URL 过期墙钟时间; service 层透传给客户端.
	ExpiresAt time.Time
}

// PresignGetInput presign GET 入参.
type PresignGetInput struct {
	Key string
	// TTL ≤ 10min (docs/modules/m4 §4.3).
	TTL time.Duration
	// Inline = true → 期望 Content-Disposition: inline (preview);
	// = false → attachment (download).
	Inline bool
	// FileName 提示 store 把 Content-Disposition 的 filename 设为它 (S3 ResponseContentDisposition);
	// 空串则不设 (用 key 末段).
	FileName string
	// ContentType 非空时强制响应 Content-Type (S3 response-content-type)。
	// 对象元数据是 octet-stream 时浏览器会无视 inline 直接下载 (2026-07-21
	// admin 材料预览实锤)——presign 时用 DB 记录的真实 mime 覆盖。inmem 桩
	// 存储的就是真实类型, 忽略此字段。
	ContentType string
}

// PresignGetOutput presign GET 出参.
type PresignGetOutput struct {
	URL       string
	ExpiresAt time.Time
}

// Stat 是一次对象元信息查询 (HEAD/Stat) 的输出 (M7 Phase A 返修第二轮).
//
// 用于 drive Confirm / ZAP AgentConfirm 在写 DB 前校验对象**真的**已经上传:
//   - presign URL 只签 content-type 不签 content-length, caller 可以声明小 size 但 PUT 大对象
//     绕过 quota, 也可以不 PUT 直接 confirm 出坏记录;
//   - Stat 把这两类绕过都堵住: size != ticket.size → 拒, 不存在 → 拒.
//
// 各字段可空意义:
//   - Size: 字节数; AWS S3 / AliYun OSS / MinIO HEAD 必然返 Content-Length, 不返时视为出错;
//   - ContentType: HEAD response 头; 客户端 PUT 时若 strip / 改了 Content-Type, 这里能看到差异;
//   - ETag: 暂未消费, 留给未来 sha256 dedup / verify.
type Stat struct {
	Size        int64
	ContentType string
	ETag        string
}

// MultipartPart F06 §3.2 / Phase 2.M: multipart upload 一片的元信息.
//
// CompleteMultipart 调用时 caller 必须传一个按 PartNumber asc 排好序的 slice;
// adapter 把它转成 S3 兼容的 XML <Part><PartNumber/><ETag/></Part> 序列.
// ETag 形式 (引号 / 无引号) adapter 内部标准化, caller 无需处理.
type MultipartPart struct {
	PartNumber int    // 1-based; S3 spec 上限 10000, drivev3 service 层进一步约束 1000
	ETag       string // S3 PUT-part response 头的 ETag (caller 从客户端 PUT 响应回填)
}

// Store 对象存储窄接口.
//
// 不暴露 Read/Write 字节: 对象数据走 presigned URL, bus 不代理. 仅 inmem
// 实现在测试用途下提供 sideload helper (见 sub-package).
type Store interface {
	// Kind 返回后端类型常量 ("s3" / "minio" / "oss" / "inmem" / ...); 用于
	// 写入 message_files.storage_kind 列.
	Kind() string

	// PresignPut presign 一次 PUT URL. ttl 由 service 层强制 ≤ 5min.
	PresignPut(ctx context.Context, in PresignPutInput) (*PresignPutOutput, error)

	// PresignGet presign 一次 GET URL. ttl 由 service 层强制 ≤ 10min.
	PresignGet(ctx context.Context, in PresignGetInput) (*PresignGetOutput, error)

	// Delete 删一个对象 (orphan worker / 显式删 message 用). idempotent: 不存在不报错.
	Delete(ctx context.Context, key string) error

	// Stat 取一个对象的最小元信息 (HEAD). 不存在 → (nil, ErrNotFound).
	//
	// M7 Phase A 返修第二轮: confirm 路径用 Stat 验证对象**真的**已上传 + size 与 ticket 一致,
	// 闭掉 "声明小 size PUT 大对象" 与 "不 PUT 直接 confirm" 两种绕过.
	Stat(ctx context.Context, key string) (*Stat, error)

	// Copy 服务端 in-place copy (同 bucket). 用于 drive upload staging→final 流程
	// (F06 §3.2). srcKey 不存在 → ErrNotFound. 同 bucket only;
	// 跨 bucket 由 caller 用多 store + Read/Write 实现.
	Copy(ctx context.Context, srcKey, dstKey string) error

	// InitMultipart F06 Phase 2.M: 启动一个 multipart upload (S3 InitiateMultipartUpload).
	// 返回 S3 分配的 uploadID, 后续 PresignPart / CompleteMultipart / AbortMultipart 都靠它路由.
	// contentType 写入对象 metadata (Content-Type), 客户端 PUT-part 不需要带 Content-Type.
	InitMultipart(ctx context.Context, key, contentType string) (uploadID string, err error)

	// PresignPart F06 Phase 2.M: 签一个 PUT-part URL.
	// partNumber 1-based; TTL 由 service 层强制 (≤30min per F06 §3.2 multipart TTL).
	// 客户端 PUT 完整 part body 后, response 头取 ETag 回传给 CompleteMultipart.
	PresignPart(ctx context.Context, key, uploadID string, partNumber int, ttl time.Duration) (url string, err error)

	// CompleteMultipart F06 Phase 2.M: 让 S3 按 parts 顺序合并 (CompleteMultipartUpload).
	// parts 必须按 PartNumber asc, ETag 不可为空. S3 校验 ETag + 序列, 任一不一致 → error.
	// 成功后 staging key 上是合并好的完整对象 (与单 PUT 等价).
	CompleteMultipart(ctx context.Context, key, uploadID string, parts []MultipartPart) error

	// AbortMultipart F06 Phase 2.M: 显式取消未完成的 multipart upload (S3 AbortMultipartUpload).
	// drivev3 bus 在 ticket 失败 / refresh 超时 / presign-part 部分失败时兜底调用.
	// idempotent: uploadID 不存在 / 已 abort / 已 complete 都不报错 (S3 返 204/404 都视为成功).
	AbortMultipart(ctx context.Context, key, uploadID string) error
}

// ErrNotFound 对象不存在.
var ErrNotFound = errors.New("object: not found")
