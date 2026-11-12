package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// fakeDoer 按 URL 提供预设响应。
type fakeDoer struct {
	responses map[string]fakeResp // key=path (URL.Path)
}

type fakeResp struct {
	status int
	body   string
	err    error
}

func (s *fakeDoer) Do(req *http.Request) (*http.Response, error) {
	r, ok := s.responses[req.URL.Path]
	if !ok {
		return &http.Response{StatusCode: 404, Body: io.NopCloser(strings.NewReader(""))}, nil
	}
	if r.err != nil {
		return nil, r.err
	}
	return &http.Response{
		StatusCode: r.status,
		Body:       io.NopCloser(bytes.NewBufferString(r.body)),
		Header:     http.Header{"Content-Type": []string{"application/json"}},
	}, nil
}

func newOKCard(multi bool) string {
	card := RuntimeCard{
		ProtocolVersion:     "zap-1.1",
		SchemaVersion:       "zap-1.1",
		Framework:           "zap",
		SupportsMultiAgent:  multi,
		MaxAgents:           1,
		RuntimeUIComponents: []string{"markdown", "error"},
	}
	if !multi {
		card.DefaultAgentKey = "main"
	} else {
		card.MaxAgents = 0
		card.AgentManagement = AgentManagement{true, true, true, true}
	}
	b, _ := json.Marshal(card)
	return string(b)
}

func newProbeSvc(doer HTTPDoer) ProbeService {
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 5*time.Minute)
	// 测试场景: fakeDoer 不真发网络, 放行 r.example.com host (不走真 DNS)。
	guard := &SSRFGuard{AllowedHosts: []string{"r.example.com"}}
	return NewProbeServiceWithOptions(tok, ProbeOptions{Doer: doer, SSRFGuard: guard})
}

func TestProbeRuntimeCardOK_SingleAgent(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(false)},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Auth:      ProbeAuth{Kind: "bearer", Secret: "s"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if !res.OK {
		t.Fatalf("expected ok; got error_code=%s msg=%s", res.ErrorCode, res.ErrorMessage)
	}
	if res.ProbeToken == "" {
		t.Fatal("probe_token must be issued on success")
	}
	if res.RuntimeCard == nil || res.RuntimeCard.DefaultAgentKey != "main" {
		t.Fatalf("runtime_card not populated: %+v", res.RuntimeCard)
	}
	if res.ProtocolVersion != "zap-1.1" {
		t.Fatalf("protocol_version=%q", res.ProtocolVersion)
	}
}

func TestProbeRuntimeCardOK_MultiAgent(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(true)},
		"/zap/v1/agents":       {status: 200, body: `{"agents":[]}`},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if !res.OK {
		t.Fatalf("expected ok; got error_code=%s msg=%s", res.ErrorCode, res.ErrorMessage)
	}
	if res.RuntimeCard == nil || !res.RuntimeCard.SupportsMultiAgent {
		t.Fatalf("runtime_card supports_multi_agent wrong: %+v", res.RuntimeCard)
	}
}

func TestProbeRuntimeCardMissing_ExpectMultiRejected(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 404, body: ""},
	}}
	svc := newProbeSvc(doer)
	expect := true
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework:        "zap",
		Endpoints:        map[string]string{"base": "https://r.example.com"},
		Scope:            "tenant",
		ExpectMultiAgent: &expect,
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.OK {
		t.Fatal("expected ok=false when runtime_card missing + expect_multi_agent=true")
	}
	if res.ErrorCode != "runtime.runtime_card_missing" {
		t.Fatalf("error_code=%q want runtime.runtime_card_missing", res.ErrorCode)
	}
}

func TestProbeRuntimeCardMissing_LegacySingleAgentAllowed(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 404, body: ""},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if !res.OK {
		t.Fatalf("expected ok=true on legacy single-agent fallback; got %+v", res)
	}
	if res.ProtocolVersion != "zap-1.0-legacy" {
		t.Fatalf("protocol_version=%q want zap-1.0-legacy", res.ProtocolVersion)
	}
}

func TestProbeMultiAgentManagementIncomplete(t *testing.T) {
	// supports_multi_agent=true 但 agent_management 任一为 false
	card := RuntimeCard{
		ProtocolVersion:     "zap-1.1",
		SchemaVersion:       "zap-1.1",
		Framework:           "zap",
		SupportsMultiAgent:  true,
		AgentManagement:     AgentManagement{true, true, false, true},
		RuntimeUIComponents: []string{"markdown", "error"},
	}
	b, _ := json.Marshal(card)
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: string(b)},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.OK {
		t.Fatal("expected ok=false when agent_management incomplete")
	}
	if res.ErrorCode != "runtime.agent_management_missing" {
		t.Fatalf("error_code=%q want runtime.agent_management_missing", res.ErrorCode)
	}
}

func TestProbeMultiAgentMissingListEndpoint(t *testing.T) {
	// agent_management 全 true 但 GET /agents 返 404
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(true)},
		"/zap/v1/agents":       {status: 404, body: ""},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.OK {
		t.Fatal("expected ok=false when GET /agents missing")
	}
	if res.ErrorCode != "runtime.agent_management_missing" {
		t.Fatalf("error_code=%q want runtime.agent_management_missing", res.ErrorCode)
	}
}

func TestProbeProbeTokenEndpointsHashConsistency(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(false)},
	}}
	tok := NewProbeTokenIssuer([]byte("0123456789abcdef0123456789abcdef"), 5*time.Minute)
	guard := &SSRFGuard{AllowedHosts: []string{"r.example.com"}}
	svc := NewProbeServiceWithOptions(tok, ProbeOptions{Doer: doer, SSRFGuard: guard})
	endpoints := map[string]string{"base": "https://r.example.com", "ws": "wss://r.example.com"}
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: endpoints,
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if !res.OK || res.ProbeToken == "" {
		t.Fatal("expected ok+token")
	}
	claims, err := tok.Verify(res.ProbeToken)
	if err != nil {
		t.Fatalf("Verify probe_token: %v", err)
	}
	if claims.EndpointsSHA256 != EndpointsSHA256(endpoints) {
		t.Fatalf("hash mismatch: token=%s expected=%s", claims.EndpointsSHA256, EndpointsSHA256(endpoints))
	}
	// 如果 create body 用了不同的 endpoints, 必须拒。
	tampered := map[string]string{"base": "https://other.example.com"}
	if claims.EndpointsSHA256 == EndpointsSHA256(tampered) {
		t.Fatal("hash collision; tampered endpoints should not match")
	}
}

func TestProbeFrameworkMismatch(t *testing.T) {
	// 用户填 openclaw 但 runtime_card 返 agno
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 200, body: newOKCard(false)},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "openclaw",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.OK {
		t.Fatal("expected ok=false on framework mismatch")
	}
	if res.ErrorCode != "runtime.framework_mismatch" {
		t.Fatalf("error_code=%q want runtime.framework_mismatch", res.ErrorCode)
	}
}

func TestProbeAuthFailed(t *testing.T) {
	doer := &fakeDoer{responses: map[string]fakeResp{
		"/zap/v1/runtime_card": {status: 401, body: ""},
	}}
	svc := newProbeSvc(doer)
	res, err := svc.Probe(context.Background(), 1, 2, ProbeRequest{
		Framework: "zap",
		Endpoints: map[string]string{"base": "https://r.example.com"},
		Scope:     "tenant",
	})
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if res.OK || res.ErrorCode != "runtime.auth_failed" {
		t.Fatalf("expected runtime.auth_failed; got %+v", res)
	}
}
