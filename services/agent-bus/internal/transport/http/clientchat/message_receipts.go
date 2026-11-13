// F09 P1 消息级已读回执 v1: GET /api/agent-bus/v1/chat/conversations/{uuid}/read-receipts.
//
// 见 docs/contracts/agent-bus-client-contract.md §「消息级已读回执 v1」+
//
//	internal/service/messagereceipts/service.go.
//
// 闸口: authT (auth + requireTenant) + service 内 AccessibleByAccount + seqs ≤ 100.
package clientchat

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/messagereceipts"
)

// ReadReceiptsService · 与 messagereceipts.Service 同形, 便于装配 / fake.
type ReadReceiptsService interface {
	GetReadReceipts(ctx context.Context, in messagereceipts.GetReadReceiptsIn) (*messagereceipts.GetReadReceiptsOut, error)
}

type ReadReceiptsHandlers struct{ ReadReceipts ReadReceiptsService }

func (h *ReadReceiptsHandlers) GetReadReceipts(w http.ResponseWriter, r *http.Request) {
	if h.ReadReceipts == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("read receipts service not wired"))
		return
	}
	convUUID := r.PathValue("uuid")
	if convUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	raw := r.URL.Query().Get("message_seq")
	if raw == "" {
		encode.JSON(w, messagereceipts.GetReadReceiptsOut{Items: []messagereceipts.ReceiptItem{}})
		return
	}
	parts := strings.Split(raw, ",")
	seqs := make([]int64, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		v, err := strconv.ParseInt(p, 10, 64)
		if err != nil || v <= 0 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("message_seq must be comma-separated positive ints"))
			return
		}
		seqs = append(seqs, v)
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	out, err := h.ReadReceipts.GetReadReceipts(r.Context(), messagereceipts.GetReadReceiptsIn{
		TenantID:         tenantID,
		CallerAccountID:  accountID,
		ConversationUUID: convUUID,
		MessageSeqs:      seqs,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}
