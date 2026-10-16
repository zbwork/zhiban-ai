// POST /api/agent-bus/v1/im/credentials
//
// 客户端登录后调用本接口拿 WuKongIM SDK 连接信息。响应不包含 WuKong 特权 REST :5001。

package clientim

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svcimconnection "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/imconnection"
)

const imCredentialsBodyMaxBytes = 4 << 10

type imCredentialsReq struct {
	DeviceID      string `json:"device_id"`
	Platform      string `json:"platform"`
	Refresh       bool   `json:"refresh,omitempty"`
	RefreshToken  string `json:"im_refresh_token,omitempty"`
	ClientVersion string `json:"client_version,omitempty"`
	OSVersion     string `json:"os_version,omitempty"`
}

type imCredentialsResp struct {
	// WuKongIM 连接信息(只含 uid/token/TCP/WS,**无 :5001**)。
	WuKong *im.ConnInfo `json:"wukong,omitempty"`
}

func (h *Handlers) Issue(w http.ResponseWriter, r *http.Request) {
	if h.WuKongCred == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("wukong imcred service not wired"))
		return
	}
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, imCredentialsBodyMaxBytes)
	body := new(bytes.Buffer)
	if _, err := body.ReadFrom(r.Body); err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("request body exceeds %d bytes", imCredentialsBodyMaxBytes))
		} else {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("read body: %v", err))
		}
		return
	}
	var req imCredentialsReq
	if body.Len() > 0 {
		if err := json.Unmarshal(body.Bytes(), &req); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid json: %v", err))
			return
		}
	}

	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if accountID <= 0 || tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}

	deviceID := ""
	platform := req.Platform
	var prepared svcimconnection.PreparedClientMetadata
	if h.IMConnectionMetadata != nil {
		var prepareErr error
		prepared, prepareErr = h.IMConnectionMetadata.Prepare(
			tenantID, accountID, req.DeviceID, req.ClientVersion, req.Platform, req.OSVersion,
		)
		if prepareErr != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(prepareErr))
			return
		}
		deviceID = prepared.DeviceID
		platform = prepared.Platform
	}

	ci, err := h.WuKongCred.Issue(r.Context(), tenantID, accountID, platform)
	if err != nil {
		encode.JSONError(w, apperr.New(apperr.UpstreamUnavailable, "imcred.wukong_upstream").Wrap(err))
		return
	}
	ci.DeviceID = deviceID
	if h.IMConnectionMetadata != nil {
		if err := h.IMConnectionMetadata.Persist(r.Context(), prepared); err != nil {
			logpkg.Default().Warn(r.Context(), "im credentials: client metadata persistence failed; credentials still issued",
				"tenant_id", tenantID, "account_id", accountID, "err", err)
		}
	}
	encode.JSON(w, imCredentialsResp{WuKong: &ci})
}
