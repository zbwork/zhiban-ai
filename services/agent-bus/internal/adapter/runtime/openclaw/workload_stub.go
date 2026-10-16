package openclaw

import (
	"context"
	"errors"
)

// StubWorkloadClient 是一个预留实现，让本地编译不依赖外部 K8s 调度系统。
//
// 真接 K8s 时换成调用 clawmanager / deployment-workloads API 的实现。
// 那个实现要做的：
//   - EnsureWorkload: POST /workloads → 拿 podIP → 返回 "http://<podIP>:18789"
//   - DeleteWorkload: DELETE /workloads/<id>
type StubWorkloadClient struct{}

func NewStubWorkloadClient() *StubWorkloadClient { return &StubWorkloadClient{} }

func (s *StubWorkloadClient) EnsureWorkload(ctx context.Context, tenantID, accountID int64, image string) (string, bool, error) {
	return "", false, errors.New("k8s workload client not implemented: please configure clawmanager / deployment-workloads endpoint")
}

func (s *StubWorkloadClient) DeleteWorkload(ctx context.Context, tenantID, accountID int64) error {
	return nil
}
