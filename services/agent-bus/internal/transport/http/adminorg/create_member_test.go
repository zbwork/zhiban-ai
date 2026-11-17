package adminorg

import (
	"context"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	svcmem "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	"net/http/httptest"
	"strings"
	"testing"
)

type createRecorder struct {
	input         svcmem.InviteInput
	tenant, actor int64
	calls         int
}

func (c *createRecorder) Invite(_ context.Context, tid, actor int64, in svcmem.InviteInput) (*svcmem.InviteResult, error) {
	c.tenant = tid
	c.actor = actor
	c.input = in
	c.calls++
	return &svcmem.InviteResult{Member: &svcmem.Member{}, AdminInitialPassword: "fixture-only"}, nil
}
func TestCreateMemberScopeAndFixedRole(t *testing.T) {
	c := &createRecorder{}
	h := Handlers{MemberCreator: c}
	r := httptest.NewRequest("POST", "/", strings.NewReader(`{"email":"new@example.test","display_name":"New","department_id":3}`))
	r = r.WithContext(middleware.ContextWithIdentityForTest(r.Context(), 7, 11))
	w := httptest.NewRecorder()
	h.CreateMember(w, r)
	if w.Code != 200 || c.tenant != 11 || c.actor != 7 || c.input.RoleCode != "tenant.member" {
		t.Fatalf("status=%d scope=%d actor=%d role=%s", w.Code, c.tenant, c.actor, c.input.RoleCode)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("temporary credential response must not be cached")
	}
}
func TestCreateMemberRejectsCredentialsAndInvalidIdentity(t *testing.T) {
	for _, body := range []string{
		`{"email":"new@example.test","display_name":"New","department_id":3,"password":"injected"}`,
		`{"email":"new@example.test","display_name":"New","department_id":3,"role_code":"tenant.admin"}`,
		`{"email":"not-email","display_name":"New","department_id":3}`,
		`{"email":"new@example.test","phone":"13800000000","display_name":"New","department_id":3}`,
		`{"email":"new@example.test","display_name":"New","department_id":0}`,
	} {
		c := &createRecorder{}
		w := httptest.NewRecorder()
		(&Handlers{MemberCreator: c}).CreateMember(w, httptest.NewRequest("POST", "/", strings.NewReader(body)))
		if w.Code != 400 || c.calls != 0 {
			t.Fatalf("invalid input reached creator: status=%d", w.Code)
		}
	}
}
