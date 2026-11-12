package directroom

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	reporoom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
)

type fakeAccountRepo struct {
	byID        map[int64]*domaccount.Account
	byUUID      map[string]*domaccount.Account
	memberships map[[2]int64]*domaccount.Membership
}

func (r fakeAccountRepo) GetByID(_ context.Context, id int64) (*domaccount.Account, error) {
	if a, ok := r.byID[id]; ok {
		return a, nil
	}
	return nil, errors.New("not found")
}

func (r fakeAccountRepo) GetByUUID(_ context.Context, uuid string) (*domaccount.Account, error) {
	if a, ok := r.byUUID[uuid]; ok {
		return a, nil
	}
	return nil, errors.New("not found")
}

func (r fakeAccountRepo) GetMembership(_ context.Context, accountID, tenantID int64) (*domaccount.Membership, error) {
	if m, ok := r.memberships[[2]int64{accountID, tenantID}]; ok {
		return m, nil
	}
	return nil, errors.New("not found")
}

type fakeRoomRepo struct {
	createCalls int
	failCreate  error
	lastInput   reporoom.CreateDirectWithPairInput
}

func (r *fakeRoomRepo) CreateDirectWithPair(_ context.Context, in reporoom.CreateDirectWithPairInput) (*reporoom.CreateDirectWithPairOutput, error) {
	r.createCalls++
	r.lastInput = in
	if r.failCreate != nil {
		return nil, r.failCreate
	}
	return &reporoom.CreateDirectWithPairOutput{
		Room:              &domroom.Room{ID: 99, UUID: "room-uuid", TenantID: in.TenantID, CreatorID: in.CallerID, RoomKind: domroom.KindDirect},
		ConversationID:    77,
		PairUUID:          "pair-uuid",
		PairCreated:       true,
		WuKongChannelID:   in.WuKongChannelID,
		WuKongChannelType: in.WuKongChannelType,
	}, nil
}

func (r *fakeRoomRepo) ConversationUUIDByRoomID(_ context.Context, roomID int64) (string, error) {
	return "conv-uuid-" + strconv.FormatInt(roomID, 10), nil
}

type fakeWuKong struct {
	calls   int
	failErr error
}

func (w *fakeWuKong) EnsureForDirect(_ context.Context, tenantID, callerAccountID int64, peerAccountUUID string) (string, int, error) {
	w.calls++
	if w.failErr != nil {
		return "", 0, w.failErr
	}
	return "t_" + strconv.FormatInt(tenantID, 10) + "_d_fake", 2, nil
}

func mkFixture() (fakeAccountRepo, *fakeRoomRepo) {
	caller := &domaccount.Account{ID: 1, UUID: "alice-uuid", DisplayName: "Alice"}
	peer := &domaccount.Account{ID: 2, UUID: "bob-uuid", DisplayName: "Bob"}
	acc := fakeAccountRepo{
		byID:   map[int64]*domaccount.Account{1: caller, 2: peer},
		byUUID: map[string]*domaccount.Account{"alice-uuid": caller, "bob-uuid": peer},
		memberships: map[[2]int64]*domaccount.Membership{
			{1, 100}: {AccountID: 1, TenantID: 100, Status: "active"},
			{2, 100}: {AccountID: 2, TenantID: 100, Status: "active"},
		},
	}
	return acc, &fakeRoomRepo{}
}

func TestCreateOrGet_WuKongHappyPath(t *testing.T) {
	acc, rooms := mkFixture()
	wk := &fakeWuKong{}
	svc := New(Deps{Rooms: rooms, Accounts: acc, WuKong: wk})

	res, err := svc.CreateOrGet(context.Background(), 1, 100, "bob-uuid", "test")
	if err != nil {
		t.Fatal(err)
	}
	if res.IMSubstrate != IMSubstrateWuKong {
		t.Errorf("expected im_substrate=wukong, got %s", res.IMSubstrate)
	}
	if res.WuKongChannelID == "" || res.WuKongChannelType != 2 {
		t.Fatalf("missing wukong channel: %+v", res)
	}
	if rooms.createCalls != 1 || wk.calls != 1 {
		t.Fatalf("createCalls=%d wk.calls=%d", rooms.createCalls, wk.calls)
	}
	if rooms.lastInput.WuKongChannelID != res.WuKongChannelID {
		t.Fatalf("wukong link not persisted through repo input: %+v", rooms.lastInput)
	}
}

func TestCreateOrGet_RejectSelf_NoProvision(t *testing.T) {
	acc, rooms := mkFixture()
	wk := &fakeWuKong{}
	svc := New(Deps{Rooms: rooms, Accounts: acc, WuKong: wk})

	_, err := svc.CreateOrGet(context.Background(), 1, 100, "alice-uuid", "")
	if err == nil || !strings.Contains(err.Error(), ErrCodeDirectSelf) {
		t.Fatalf("expected %s, got %v", ErrCodeDirectSelf, err)
	}
	if rooms.createCalls != 0 || wk.calls != 0 {
		t.Fatalf("must not create/provision on self chat; create=%d wk=%d", rooms.createCalls, wk.calls)
	}
}

func TestCreateOrGet_RejectCrossTenant_NoProvision(t *testing.T) {
	acc, rooms := mkFixture()
	wk := &fakeWuKong{}
	svc := New(Deps{Rooms: rooms, Accounts: acc, WuKong: wk})

	_, err := svc.CreateOrGet(context.Background(), 1, 999, "bob-uuid", "")
	if err == nil || !strings.Contains(err.Error(), ErrCodeDirectPeerCrossTenant) {
		t.Fatalf("expected %s, got %v", ErrCodeDirectPeerCrossTenant, err)
	}
	if rooms.createCalls != 0 || wk.calls != 0 {
		t.Fatalf("must not create/provision on cross tenant; create=%d wk=%d", rooms.createCalls, wk.calls)
	}
}

func TestCreateOrGet_RejectInactiveMembership_NoProvision(t *testing.T) {
	acc, rooms := mkFixture()
	acc.memberships[[2]int64{2, 100}].Status = "suspended"
	wk := &fakeWuKong{}
	svc := New(Deps{Rooms: rooms, Accounts: acc, WuKong: wk})

	_, err := svc.CreateOrGet(context.Background(), 1, 100, "bob-uuid", "")
	if err == nil || !strings.Contains(err.Error(), ErrCodeDirectPeerCrossTenant) {
		t.Fatalf("expected %s, got %v", ErrCodeDirectPeerCrossTenant, err)
	}
	if rooms.createCalls != 0 || wk.calls != 0 {
		t.Fatalf("must not create/provision on inactive peer; create=%d wk=%d", rooms.createCalls, wk.calls)
	}
}

func TestCreateOrGet_WuKongFailure_NoRoomCreated(t *testing.T) {
	acc, rooms := mkFixture()
	wk := &fakeWuKong{failErr: errors.New("wukong 502")}
	svc := New(Deps{Rooms: rooms, Accounts: acc, WuKong: wk})

	_, err := svc.CreateOrGet(context.Background(), 1, 100, "bob-uuid", "")
	if err == nil || !strings.Contains(err.Error(), "directroom.wukong_ensure_failed") {
		t.Fatalf("expected wukong ensure error, got %v", err)
	}
	if rooms.createCalls != 0 || wk.calls != 1 {
		t.Fatalf("room must not be created after wukong failure; create=%d wk=%d", rooms.createCalls, wk.calls)
	}
}
