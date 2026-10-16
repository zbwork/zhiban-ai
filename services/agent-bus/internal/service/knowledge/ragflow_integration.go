// ragflow_integration.go — F07 集成胶水。
//
// 把 lazy provision / 真上传 / 异步删 / ZAP capability check / 跨用户审计 等 F07 集成点
// 集中在本文件, 主 service.go 仅在关键 hook 点调用 (impl.maybe*)。
package knowledge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repoevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

func tenantIDForKB(kb *domkb.KnowledgeBase) (int64, error) {
	if kb == nil || kb.TenantID == nil || *kb.TenantID <= 0 {
		return 0, fmt.Errorf("tenant-scoped RAGFlow path requires tenant knowledge base")
	}
	return *kb.TenantID, nil
}

func (s *impl) releaseQuotaForKB(ctx context.Context, tx pgx.Tx, kb *domkb.KnowledgeBase, tenantID, bytes int64) error {
	if isPlatformAgentKB(kb) {
		return s.repo.ReleasePlatformQuotaBytes(ctx, tx, bytes)
	}
	return s.releaseKnowledgeQuota(ctx, tx, tenantID, bytes)
}

// outboxOpDeleteDataset / opTenantCleanup* 跟 internal/domain/kboutbox/event.go 的常量一致;
// 本文件不引 kboutbox 包以避免循环依赖, 用 string literal。
const (
	outboxOpDeleteDataset         = "delete_dataset"
	outboxOpTenantCleanupDatasets = "tenant_cleanup_datasets"
	outboxOpTenantCleanupUser     = "tenant_cleanup_user"
)

// maybeEnsureRagflowDataset — CreateKB 成功 commit 后调:
// 若 RagflowExt 注入了, lazy 在 RAGFlow 那侧建 dataset, 并 UPDATE knowledge_bases.ragflow_dataset_id。
//
// 失败时 KB 行保留 (provision_status='failed'), 并把错误交给 CreateKB 映射为
// kb.provider_degraded;客户端不能看到"创建成功但列表为空"。
//
// 注: provision_status 列由 migration 000070 加, 默认 'pending'。
func (s *impl) maybeEnsureRagflowDataset(ctx context.Context, kb *domkb.KnowledgeBase) error {
	if s.ragflowExt == nil {
		if strings.EqualFold(kb.ProviderKind, "ragflow") {
			if _, updateErr := s.pool.Exec(ctx,
				`UPDATE knowledge_bases SET provision_status='failed', updated_at=now() WHERE id=$1`, kb.ID,
			); updateErr != nil {
				s.logger.Warn(ctx, "ragflow mark kb provision failed failed", "kb_id", kb.ID, "err", updateErr)
			}
			return fmt.Errorf("ragflow provider not wired")
		}
		// 没 ragflow 集成 (走 stub provider 模式), 把 status 直接标 active 不阻塞业务
		if _, err := s.pool.Exec(ctx,
			`UPDATE knowledge_bases SET provision_status='active', updated_at=now() WHERE id=$1`, kb.ID,
		); err != nil {
			return fmt.Errorf("mark kb provision active: %w", err)
		}
		return nil
	}
	tenantID := int64(0)
	var datasetID string
	var err error
	if isPlatformAgentKB(kb) {
		scoped, ok := s.ragflowExt.(ScopedRagflowExtension)
		if !ok {
			return fmt.Errorf("platform ragflow principal not wired")
		}
		datasetID, err = scoped.EnsureDatasetForKB(ctx, 0, kb.ID, kb.Name)
	} else {
		tenantID, err = tenantIDForKB(kb)
		if err == nil {
			datasetID, err = s.ragflowExt.EnsureDataset(ctx, tenantID, kb.Name)
		}
	}
	if err != nil {
		s.logger.Warn(ctx, "ragflow ensure dataset failed", "kb_id", kb.ID, "err", err)
		if _, updateErr := s.pool.Exec(ctx,
			`UPDATE knowledge_bases SET provision_status='failed', updated_at=now() WHERE id=$1`, kb.ID,
		); updateErr != nil {
			s.logger.Warn(ctx, "ragflow mark kb provision failed failed", "kb_id", kb.ID, "err", updateErr)
		}
		return fmt.Errorf("ragflow ensure dataset: %w", err)
	}
	if _, err := s.pool.Exec(ctx,
		`UPDATE knowledge_bases SET ragflow_dataset_id=$2, provision_status='active', updated_at=now() WHERE id=$1`,
		kb.ID, datasetID); err != nil {
		s.logger.Warn(ctx, "ragflow update kb dataset_id failed", "kb_id", kb.ID, "err", err)
		return fmt.Errorf("update kb ragflow dataset id: %w", err)
	}
	return nil
}

// maybeUploadToRagflow — UploadDocument 在 stub provider.IngestChunks 之后调:
// 若 RagflowExt 注入且 KB 有 ragflow_dataset_id, 走真 multipart upload, 把 ragflow_document_id 回写。
func (s *impl) maybeUploadToRagflow(ctx context.Context, kb *domkb.KnowledgeBase, docID int64, title, mime string, content []byte) {
	if s.ragflowExt == nil {
		return
	}
	// 取 KB 的 ragflow_dataset_id
	var datasetID string
	err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(ragflow_dataset_id, '') FROM knowledge_bases WHERE id=$1`, kb.ID).Scan(&datasetID)
	if err != nil || datasetID == "" {
		s.logger.Warn(ctx, "ragflow upload skipped kb=%d (no dataset_id, provision not done): err=%v", kb.ID, err)
		return
	}
	filename := title
	if filename == "" {
		filename = "untitled"
	}
	var ragflowDocID string
	if isPlatformAgentKB(kb) {
		scoped, ok := s.ragflowExt.(ScopedRagflowExtension)
		if !ok {
			s.logger.Warn(ctx, "platform ragflow upload skipped: resolver not wired", "kb_id", kb.ID)
			return
		}
		ragflowDocID, err = scoped.UploadFileForKB(ctx, 0, kb.ID, datasetID, filename, content)
	} else {
		tenantID, tenantErr := tenantIDForKB(kb)
		if tenantErr != nil {
			s.logger.Warn(ctx, "ragflow upload skipped for invalid tenant kb", "kb_id", kb.ID)
			return
		}
		ragflowDocID, err = s.ragflowExt.UploadFile(ctx, tenantID, datasetID, filename, content)
	}
	if err != nil {
		s.logger.Warn(ctx, "ragflow upload doc kb=%d doc=%d err: %v", kb.ID, docID, err)
		return
	}
	_, _ = s.pool.Exec(ctx,
		`UPDATE kb_documents SET ragflow_document_id=$2, updated_at=now() WHERE id=$1`,
		docID, ragflowDocID)
}

func (s *impl) uploadDocumentToRagflowSync(ctx context.Context, accountID, tenantID int64, kb *domkb.KnowledgeBase, doc *domkb.Document, title, mime string, content []byte, chunkCount int) (*DocumentDTO, error) {
	datasetID, err := s.ensureRagflowDatasetIDForUpload(ctx, kb)
	if err != nil || datasetID == "" {
		reason := "ragflow dataset not ready"
		if err != nil {
			reason = err.Error()
		}
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			_ = s.repo.MarkDocumentFailed(ctx, tx, doc.ID, truncateErrMsg(reason))
			_ = s.releaseQuotaForKB(ctx, tx, kb, tenantID, doc.FileSize)
			s.publishAuditTx(ctx, tx, "audit.kb.ingest_failed", tenantID, map[string]any{
				"account_id": accountID, "kb_uuid": kb.UUID, "document_uuid": doc.UUID, "reason": reason,
			})
			return nil
		})
		s.notify(ctx, "kb_documents:"+kb.UUID)
		return nil, apperr.ErrUpstreamUnavailable.Withf("kb.provider_degraded: ragflow dataset not ready")
	}
	var ragflowDocID string
	if isPlatformAgentKB(kb) {
		scoped, ok := s.ragflowExt.(ScopedRagflowExtension)
		if !ok {
			err = fmt.Errorf("platform ragflow principal not wired")
		} else {
			ragflowDocID, err = scoped.UploadFileForKB(ctx, 0, kb.ID, datasetID, title, content)
		}
	} else {
		ragflowDocID, err = s.ragflowExt.UploadFile(ctx, tenantID, datasetID, title, content)
	}
	if err != nil {
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			_ = s.repo.MarkDocumentFailed(ctx, tx, doc.ID, truncateErrMsg(err.Error()))
			_ = s.releaseQuotaForKB(ctx, tx, kb, tenantID, doc.FileSize)
			s.publishAuditTx(ctx, tx, "audit.kb.ingest_failed", tenantID, map[string]any{
				"account_id": accountID, "kb_uuid": kb.UUID, "document_uuid": doc.UUID, "reason": truncateErrMsg(err.Error()),
			})
			return nil
		})
		s.notify(ctx, "kb_documents:"+kb.UUID)
		return nil, apperr.ErrInternal.Wrap(err)
	}
	var dto *DocumentDTO
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
UPDATE kb_documents
   SET status='ready',
       chunk_count=$2,
       provider_doc_id=$3,
       ragflow_document_id=$3,
       error_message='',
       updated_at=now()
 WHERE id=$1`, doc.ID, chunkCount, ragflowDocID); err != nil {
			return err
		}
		if err := s.repo.IncrTotalDocuments(ctx, tx, kb.ID, 1); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.kb.ingest", tenantID, map[string]any{
			"account_id": accountID, "kb_uuid": kb.UUID, "document_uuid": doc.UUID,
			"ragflow_document_id": ragflowDocID, "file_size": int64(len(content)),
		})
		d := *doc
		d.ChunkCount = chunkCount
		d.ProviderDocID = ragflowDocID
		d.Status = domkb.DocStatusReady
		d.ErrorMessage = ""
		out := toDocumentDTO(&d, kb.UUID)
		dto = &out
		return nil
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "kb_documents:"+kb.UUID)
	return dto, nil
}

func (s *impl) ensureRagflowDatasetIDForUpload(ctx context.Context, kb *domkb.KnowledgeBase) (string, error) {
	var datasetID string
	err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(ragflow_dataset_id, '') FROM knowledge_bases WHERE id=$1 AND provision_status='active'`, kb.ID).Scan(&datasetID)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(datasetID) != "" {
		return datasetID, nil
	}
	if !strings.EqualFold(kb.ProviderKind, "ragflow") {
		return "", fmt.Errorf("kb provider %q has no ragflow dataset", kb.ProviderKind)
	}
	if err := s.maybeEnsureRagflowDataset(ctx, kb); err != nil {
		return "", err
	}
	err = s.pool.QueryRow(ctx,
		`SELECT COALESCE(ragflow_dataset_id, '') FROM knowledge_bases WHERE id=$1 AND provision_status='active'`, kb.ID).Scan(&datasetID)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(datasetID) == "" {
		return "", fmt.Errorf("ragflow dataset id is empty after provision")
	}
	return datasetID, nil
}

// enqueueDeleteDatasetTx writes the provider cleanup task in the same
// transaction as the business soft-delete. A delete cannot commit without a
// durable, scope-aware cleanup record.
func (s *impl) enqueueDeleteDatasetTx(ctx context.Context, tx pgx.Tx, kb *domkb.KnowledgeBase) error {
	datasetID := strings.TrimSpace(kb.RagflowDatasetID)
	if datasetID == "" {
		return nil
	}
	payload, err := json.Marshal(map[string]string{
		"kb_uuid":            kb.UUID,
		"ragflow_dataset_id": datasetID,
	})
	if err != nil {
		return err
	}
	scopeKind := domkb.ScopeTenant
	tenantID := kb.TenantID
	if isPlatformAgentKB(kb) {
		scopeKind = domkb.ScopePlatform
		tenantID = nil
	}
	return s.repo.InsertKBOutbox(ctx, tx, string(scopeKind), tenantID, kb.ID, outboxOpDeleteDataset, payload)
}

// EnqueueTenantCleanup — 租户硬删时调 (account.lifecycle 事件); 插 2 条 outbox: 先 cleanup_datasets, 再 cleanup_user。
// 实际执行由 kb_outbox worker 异步跑。
func (s *impl) EnqueueTenantCleanup(ctx context.Context, tenantID int64, ragflowEmail string) error {
	if s.outboxRepo == nil {
		return fmt.Errorf("outbox repo not wired")
	}
	if ragflowEmail == "" {
		return fmt.Errorf("ragflow_email required")
	}
	payloadEmpty, _ := json.Marshal(map[string]string{"ragflow_email": ragflowEmail})
	if err := s.outboxRepo.Insert(ctx, tenantID, outboxOpTenantCleanupDatasets, payloadEmpty); err != nil {
		return fmt.Errorf("insert cleanup_datasets: %w", err)
	}
	if err := s.outboxRepo.Insert(ctx, tenantID, outboxOpTenantCleanupUser, payloadEmpty); err != nil {
		return fmt.Errorf("insert cleanup_user: %w", err)
	}
	return nil
}

// assertAgentKBBound uses agent_kb_bindings as the only KB authorization
// source. Migration 000092 backfills the legacy generic capability rows before
// this cutover, so missing wiring or an absent binding must fail closed.
func (s *impl) assertAgentKBBound(ctx context.Context, agentID, kbID, tenantID int64, callerAccountID int64, kbUUID string) error {
	if agentID <= 0 || s.agentKBRepo == nil {
		return apperr.ErrInternal.Withf("canonical agent kb binding repository not wired")
	}
	bound, err := s.agentKBRepo.IsBound(ctx, agentID, kbID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if bound {
		return nil
	}
	s.publishAudit(ctx, "agent.kb.binding_missing", tenantID, map[string]any{
		"caller_account_id": callerAccountID,
		"agent_id":          agentID,
		"kb_uuid":           kbUUID,
	})
	return apperr.New(apperr.Forbidden, ErrCodeKBPermissionDenied).
		Withf("agent not bound to kb")
}

// publishAudit · 简单 audit helper (非 tx 版本; 主流程 publishAuditTx 已有 tx 版)。
// 用独立 tx, 失败不阻塞主流程。
func (s *impl) publishAudit(ctx context.Context, kind string, tenantID int64, payload map[string]any) {
	if s.audit == nil {
		return
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_ = s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.audit.Publish(ctx, repoevent.WrapTx(tx), domevent.Event{
			Topic: kind, TenantID: tenantID, Payload: body,
		}); err != nil && !errors.Is(err, domevent.ErrDuplicate) {
			s.logger.Warn(ctx, "knowledge: audit publish failed", "topic", kind, "err", err)
		}
		return nil
	})
}

// ListUserPrivateKB — F07 §3.2 D13 跨用户列私有 KB (审计敏感)。
// 调用方典型: external/kb.go::kbListUserPrivate handler。
//
// 前置: caller 应已通过 RequireExternalScope("tenant.kb.list_user_private") 检查。
//
// 内部:
//  1. 校验 targetAccountID 属于 tenantID (防跨租户)
//  2. SELECT FROM knowledge_bases WHERE owner_account_id=$1 AND space_kind='personal'
//  3. 写审计事件 'tenant.admin.user_kb_inspect'
func (s *impl) ListUserPrivateKB(ctx context.Context, tenantID, targetAccountID int64, apiKeyPrefix string, scopesUsed []string) ([]KBDTO, error) {
	if tenantID <= 0 || targetAccountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant/target account required")
	}
	// 校验 target 是该租户内的 user
	var targetTenantID int64
	err := s.pool.QueryRow(ctx, `
SELECT tenant_id FROM tenant_memberships
WHERE account_id=$1 AND tenant_id=$2 AND status='active'`, targetAccountID, tenantID).Scan(&targetTenantID)
	if err != nil || targetTenantID != tenantID {
		return nil, apperr.New(apperr.NotFound, "tenant.user.not_found").
			Withf("target account %d not in tenant %d", targetAccountID, tenantID)
	}

	// 直查 knowledge_bases — 不走 repo (repo 没暴露此 method)
	rows, err := s.pool.Query(ctx, `
SELECT id, uuid::text, tenant_id, creator_id, owner_account_id, space_kind, name, COALESCE(description,''),
       visibility, status, provider_id, COALESCE(provider_kind,'stub'), COALESCE(ragflow_dataset_id,''),
       COALESCE(provision_status,'active'),
       COALESCE((SELECT count(*)::int FROM kb_documents d WHERE d.kb_id=k.id AND d.deleted_at IS NULL), 0) AS doc_count,
       retrieval_config, metadata, created_at, updated_at
FROM knowledge_bases k
WHERE tenant_id=$1 AND space_kind='personal' AND owner_account_id=$2 AND deleted_at IS NULL
ORDER BY updated_at DESC LIMIT 200`, tenantID, targetAccountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()
	out := make([]KBDTO, 0)
	for rows.Next() {
		kb, err := scanServiceKB(rows)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		out = append(out, s.toKBDTO(kb))
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// D13 审计 (必写, 即便 caller 是空 admin 角色)
	s.publishAudit(ctx, "tenant.admin.user_kb_inspect", tenantID, map[string]any{
		"target_account_id": targetAccountID,
		"api_key_prefix":    apiKeyPrefix,
		"scopes_used":       scopesUsed,
		"result_count":      len(out),
	})
	return out, nil
}

// TransferUserKBOnDeactivation — R-10.4 离职用户的个人 KB 自动转给 admin (变 space_kind='tenant', owner=NULL)。
// 调用方典型: cmd/admin user deactivation flow。
func (s *impl) TransferUserKBOnDeactivation(ctx context.Context, tenantID, leavingAccountID int64) (int, error) {
	tag, err := s.pool.Exec(ctx, `
UPDATE knowledge_bases
SET space_kind='tenant', visibility='tenant', owner_account_id=NULL, updated_at=now()
WHERE tenant_id=$1 AND space_kind='personal' AND owner_account_id=$2 AND deleted_at IS NULL`,
		tenantID, leavingAccountID)
	if err != nil {
		return 0, apperr.ErrInternal.Wrap(err)
	}
	n := int(tag.RowsAffected())
	if n > 0 {
		s.publishAudit(ctx, "tenant.user.kb_transferred_on_deactivation", tenantID, map[string]any{
			"leaving_account_id": leavingAccountID,
			"kb_count":           n,
		})
	}
	return n, nil
}

// RetryIngest — R-2.3 解析失败的文档人工 retry。
// 重置 status 到 'pending' + 调 maybeUploadToRagflow (用现存 storage_key 内容)。
// 简化版本: 仅重置 status, 让 worker 重新拉取 RAGFlow 那侧 (实际 RAGFlow API 是 /datasets/<id>/chunks)。
func (s *impl) RetryIngest(ctx context.Context, accountID, tenantID int64, perms []string, kbUUID, docUUID string) error {
	kb, err := s.resolveAccessibleKB(ctx, kbUUID, accountID, tenantID)
	if err != nil {
		return err
	}
	if err := assertCanModify(kb, accountID, perms); err != nil {
		return err
	}
	var docID int64
	var fileSize int64
	var status string
	err = s.pool.QueryRow(ctx,
		`SELECT id, status, COALESCE(file_size,0) FROM kb_documents WHERE uuid=$1 AND kb_id=$2 AND deleted_at IS NULL`,
		docUUID, kb.ID).Scan(&docID, &status, &fileSize)
	if err != nil {
		return apperr.New(apperr.NotFound, "kb.doc.not_found").Wrap(err)
	}
	if status != "failed" {
		return apperr.ErrInvalidParams.Withf("doc status=%s, only 'failed' supports retry", status)
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.reserveKnowledgeQuota(ctx, tx, tenantID, fileSize); err != nil {
			return err
		}
		_, err := tx.Exec(ctx,
			`UPDATE kb_documents SET status='pending', error_message='', updated_at=now() WHERE id=$1`, docID)
		return err
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return e
		}
		return apperr.ErrInternal.Wrap(err)
	}
	s.publishAudit(ctx, "kb.doc.retry_requested", tenantID, map[string]any{
		"account_id": accountID, "kb_uuid": kbUUID, "doc_uuid": docUUID,
	})
	return nil
}

// resolveChunkDocUUIDs — Codex P2 #1 修复。
//
// RAGFlow provider 路径下 ChunkDTO.UUID 被复用成 ragflow_document_id (RAGFlow 那侧的 doc id),
// 不是 agent-bus 的 kb_documents.uuid。external retrieve / SDK 客户端期望拿到真 uuid 才能
// 调 GET /kb/{uuid}/documents/{doc_uuid} 之类后续接口。这里 batched 查 kb_documents 把
// ragflow_document_id → (id, uuid) 映射建出来, 然后原地改写每个 chunk。
//
// 对 stub provider 路径 (Source != "ragflow") 不改, 因为它们的 UUID 已经是真 chunk uuid。
// 对 ragflow chunk 但找不到映射 (例如 KB 重建中) 的, 清空 UUID 并保留 Source 字段做 debug。
func (s *impl) resolveChunkDocUUIDs(ctx context.Context, kbID int64, chunks []ChunkDTO) {
	// 收集所有 ragflow chunk 的 doc id (=UUID 字段)
	want := make([]string, 0, len(chunks))
	seen := make(map[string]bool, len(chunks))
	for _, c := range chunks {
		if c.Source != "ragflow" || c.UUID == "" {
			continue
		}
		if !seen[c.UUID] {
			seen[c.UUID] = true
			want = append(want, c.UUID)
		}
	}
	if len(want) == 0 {
		return
	}
	rows, err := s.pool.Query(ctx,
		`SELECT id, uuid::text, title, ragflow_document_id
		   FROM kb_documents
		  WHERE kb_id=$1 AND ragflow_document_id = ANY($2) AND deleted_at IS NULL`,
		kbID, want)
	if err != nil {
		// 找不到 → 不破坏调用方; chunks 留原状, 上层日志层捕获
		return
	}
	defer rows.Close()
	type docRef struct {
		id    int64
		uuid  string
		title string
	}
	m := make(map[string]docRef, len(want))
	for rows.Next() {
		var id int64
		var u, title, rgID string
		if err := rows.Scan(&id, &u, &title, &rgID); err != nil {
			continue
		}
		m[rgID] = docRef{id: id, uuid: u, title: title}
	}
	// 原地改写 chunks
	for i := range chunks {
		if chunks[i].Source != "ragflow" {
			continue
		}
		ref, ok := m[chunks[i].UUID]
		if !ok {
			// 找不到对应 kb_documents → 清 UUID 防止客户端把 ragflow 内部 id 当真 uuid 用
			chunks[i].UUID = ""
			continue
		}
		chunks[i].UUID = ref.uuid
		chunks[i].DocumentID = ref.id
		chunks[i].DocumentTitle = ref.title
	}
}
