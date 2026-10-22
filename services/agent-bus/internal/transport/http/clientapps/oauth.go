package clientapps

import (
	"encoding/json"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	rl "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/ratelimit"
	"io"
	"mime"
	"net/http"
	"time"
)

type oauthTokenReq struct {
	GrantType    string `json:"grant_type"`
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	Code         string `json:"code"`
	RedirectURI  string `json:"redirect_uri"`
	RefreshToken string `json:"refresh_token"`
}

var limiter = rl.NewClientIDLimiter(5, 1)

func (h *Handlers) Token(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var req oauthTokenReq
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if r.Header.Get("Content-Type") == "" {
		mt = "application/json"
		err = nil
	}
	if err == nil {
		switch mt {
		case "application/json":
			d := json.NewDecoder(r.Body)
			d.DisallowUnknownFields()
			err = d.Decode(&req)
			if err == nil && d.Decode(new(any)) != io.EOF {
				err = io.ErrUnexpectedEOF
			}
		case "application/x-www-form-urlencoded":
			err = r.ParseForm()
			req = oauthTokenReq{r.PostForm.Get("grant_type"), r.PostForm.Get("client_id"), r.PostForm.Get("client_secret"), r.PostForm.Get("code"), r.PostForm.Get("redirect_uri"), r.PostForm.Get("refresh_token")}
		default:
			err = io.ErrUnexpectedEOF
		}
	}
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	if id, secret, ok := r.BasicAuth(); ok {
		req.ClientID = id
		req.ClientSecret = secret
	}
	if !limiter.Allow(req.ClientID, time.Now()) {
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	switch req.GrantType {
	case "authorization_code":
		h.oauthAuthorizationCodeGrant(w, r, req)
	case "refresh_token":
		h.oauthRefreshTokenGrant(w, r, req)
	default:
		encode.JSONError(w, apperr.ErrInvalidParams)
	}
}
func writeOAuthTokenJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(body)
}
