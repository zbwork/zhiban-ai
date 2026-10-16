// workerjob.go — F06 §4.7 2026-07-06 增补: drive-worker 失败对象明细.
package drive

import "time"

// WorkerJobFailure drive_worker_job_failures 一行: 某轮 job 中单个对象的失败原因.
// 「最近失败对象」有界诊断数据 (每轮 <= batch 上限, 14 天滚动保留), 非完整 run history.
type WorkerJobFailure struct {
	ID         int64
	Job        string
	TenantID   *int64 // 解析不出所属租户时为 nil
	ObjectKind string // upload_ticket / recycle_entry / file / file_version
	ObjectRef  string // uuid 或数字 id 的文本形式
	Reason     string
	OccurredAt time.Time
}
