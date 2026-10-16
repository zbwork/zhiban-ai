// Package tenantadmin enforces tenant-owner and last-super-admin invariants
// inside the caller's mutation transaction.
package tenantadmin

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type tenantState struct {
	ownerAccountID *int64
	protected      bool
}

type memberMutationState struct {
	isOwner              bool
	targetIsAdmin        bool
	actorIsAdmin         bool
	otherAdminCount      int64
	protectAdminPresence bool
}

func validateMemberRemoval(state memberMutationState) error {
	if state.isOwner {
		return apperr.ErrConflict.Withf("租户创建人不能直接移出，请先转让租户所有权")
	}
	if !state.targetIsAdmin {
		return nil
	}
	if !state.actorIsAdmin {
		return apperr.ErrForbidden.Withf("普通管理员不能移出超级管理员")
	}
	if state.protectAdminPresence && state.otherAdminCount == 0 {
		return apperr.ErrConflict.Withf("该成员是租户最后一名超级管理员，请先将其他成员设为超级管理员")
	}
	return nil
}

func validateMemberDeactivation(state memberMutationState) error {
	if state.isOwner {
		return apperr.ErrConflict.Withf("租户创建人不能改为非在职状态，请先转让租户所有权")
	}
	if !state.targetIsAdmin {
		return nil
	}
	if !state.actorIsAdmin {
		return apperr.ErrForbidden.Withf("普通管理员不能将超级管理员改为非在职状态")
	}
	if state.protectAdminPresence && state.otherAdminCount == 0 {
		return apperr.ErrConflict.Withf("该成员是租户最后一名超级管理员，请先将其他成员设为超级管理员")
	}
	return nil
}

func validateAdminRevocation(protectAdminPresence, targetIsAdmin bool, otherAdminCount int64) error {
	if protectAdminPresence && targetIsAdmin && otherAdminCount == 0 {
		return apperr.ErrConflict.Withf("该成员是租户最后一名超级管理员，请先将其他成员设为超级管理员")
	}
	return nil
}

// EnsureMemberRemovalAllowed serializes membership-removal checks per tenant.
// The caller must perform the actual mutation using the same transaction.
func EnsureMemberRemovalAllowed(
	ctx context.Context,
	tx pgx.Tx,
	tenantID, actorAccountID, targetAccountID int64,
) error {
	state, err := loadMemberMutationState(ctx, tx, tenantID, actorAccountID, targetAccountID)
	if err != nil {
		return err
	}
	return validateMemberRemoval(state)
}

// EnsureMemberStatusChangeAllowed protects owner/administrator membership when
// the requested status would make the member inactive.
func EnsureMemberStatusChangeAllowed(
	ctx context.Context,
	tx pgx.Tx,
	tenantID, actorAccountID, targetAccountID int64,
	status string,
) error {
	if status == "active" {
		return nil
	}
	state, err := loadMemberMutationState(ctx, tx, tenantID, actorAccountID, targetAccountID)
	if err != nil {
		return err
	}
	return validateMemberDeactivation(state)
}

// EnsureAssignmentRevocationAllowed protects a tenant.admin assignment
// identified by its primary key. Platform and workspace assignments, expired
// assignments, inactive members and impersonate grants do not count.
func EnsureAssignmentRevocationAllowed(ctx context.Context, tx pgx.Tx, assignmentID int64) error {
	var accountID, tenantID int64
	var roleCode, grantedReason string
	err := tx.QueryRow(ctx, `
		SELECT ra.account_id, COALESCE(ra.tenant_id, 0), r.code, COALESCE(ra.granted_reason, '')
		  FROM role_assignments ra
		  JOIN roles r ON r.id = ra.role_id
		 WHERE ra.id=$1 AND ra.deleted_at IS NULL`,
		assignmentID).Scan(&accountID, &tenantID, &roleCode, &grantedReason)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if tenantID == 0 || roleCode != "tenant.admin" || grantedReason == "impersonate" {
		return nil
	}
	return ensureAdminRevocationAllowed(ctx, tx, tenantID, accountID)
}

// EnsureAssignmentTupleRevocationAllowed protects a tenant.admin assignment
// identified by the tuple used by the Admin member-role endpoint.
func EnsureAssignmentTupleRevocationAllowed(
	ctx context.Context,
	tx pgx.Tx,
	accountID, roleID int64,
	scopeKind string,
	tenantID, workspaceID *int64,
) error {
	if scopeKind != "tenant" || tenantID == nil || workspaceID != nil {
		return nil
	}
	state, err := lockTenant(ctx, tx, *tenantID)
	if err != nil {
		return err
	}
	var roleCode, grantedReason string
	err = tx.QueryRow(ctx, `
		SELECT r.code, COALESCE(ra.granted_reason, '')
		  FROM role_assignments ra
		  JOIN roles r ON r.id = ra.role_id
		 WHERE ra.account_id=$1 AND ra.role_id=$2 AND ra.scope_kind='tenant'
		   AND ra.tenant_id=$3 AND ra.workspace_id IS NULL
		   AND ra.deleted_at IS NULL`,
		accountID, roleID, *tenantID).Scan(&roleCode, &grantedReason)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if roleCode != "tenant.admin" || grantedReason == "impersonate" {
		return nil
	}
	targetIsAdmin, err := effectiveTenantAdmin(ctx, tx, *tenantID, accountID)
	if err != nil {
		return err
	}
	otherCount, err := effectiveTenantAdminCountExcept(ctx, tx, *tenantID, accountID)
	if err != nil {
		return err
	}
	return validateAdminRevocation(state.protected, targetIsAdmin, otherCount)
}

func ensureAdminRevocationAllowed(ctx context.Context, tx pgx.Tx, tenantID, accountID int64) error {
	state, err := lockTenant(ctx, tx, tenantID)
	if err != nil {
		return err
	}
	targetIsAdmin, err := effectiveTenantAdmin(ctx, tx, tenantID, accountID)
	if err != nil {
		return err
	}
	otherCount, err := effectiveTenantAdminCountExcept(ctx, tx, tenantID, accountID)
	if err != nil {
		return err
	}
	return validateAdminRevocation(state.protected, targetIsAdmin, otherCount)
}

func loadMemberMutationState(
	ctx context.Context,
	tx pgx.Tx,
	tenantID, actorAccountID, targetAccountID int64,
) (memberMutationState, error) {
	tenant, err := lockTenant(ctx, tx, tenantID)
	if err != nil {
		return memberMutationState{}, err
	}
	targetIsAdmin, err := effectiveTenantAdmin(ctx, tx, tenantID, targetAccountID)
	if err != nil {
		return memberMutationState{}, err
	}
	actorIsAdmin := false
	if actorAccountID > 0 {
		actorIsAdmin, err = effectiveTenantAdmin(ctx, tx, tenantID, actorAccountID)
		if err != nil {
			return memberMutationState{}, err
		}
	}
	otherCount, err := effectiveTenantAdminCountExcept(ctx, tx, tenantID, targetAccountID)
	if err != nil {
		return memberMutationState{}, err
	}
	return memberMutationState{
		isOwner:              tenant.ownerAccountID != nil && *tenant.ownerAccountID == targetAccountID,
		targetIsAdmin:        targetIsAdmin,
		actorIsAdmin:         actorIsAdmin,
		otherAdminCount:      otherCount,
		protectAdminPresence: tenant.protected,
	}, nil
}

func lockTenant(ctx context.Context, tx pgx.Tx, tenantID int64) (tenantState, error) {
	var owner pgtype.Int8
	var status string
	err := tx.QueryRow(ctx, `
		SELECT owner_id, status
		  FROM tenants
		 WHERE id=$1 AND deleted_at IS NULL
		 FOR UPDATE`,
		tenantID).Scan(&owner, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return tenantState{}, apperr.ErrNotFound.Withf("租户不存在")
	}
	if err != nil {
		return tenantState{}, err
	}
	state := tenantState{protected: status == "trial" || status == "active"}
	if owner.Valid {
		id := owner.Int64
		state.ownerAccountID = &id
	}
	return state, nil
}

func effectiveTenantAdmin(ctx context.Context, tx pgx.Tx, tenantID, accountID int64) (bool, error) {
	var exists bool
	err := tx.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1
			  FROM tenant_memberships tm
			  JOIN role_assignments ra
			    ON ra.account_id=tm.account_id
			   AND ra.tenant_id=tm.tenant_id
			   AND ra.scope_kind='tenant'
			  JOIN roles r ON r.id=ra.role_id
			 WHERE tm.tenant_id=$1
			   AND tm.account_id=$2
			   AND tm.deleted_at IS NULL
			   AND tm.status='active'
			   AND ra.deleted_at IS NULL
			   AND (ra.expires_at IS NULL OR ra.expires_at > now())
			   AND COALESCE(ra.granted_reason, '') <> 'impersonate'
			   AND r.deleted_at IS NULL
			   AND r.code='tenant.admin'
		)`, tenantID, accountID).Scan(&exists)
	return exists, err
}

func effectiveTenantAdminCountExcept(ctx context.Context, tx pgx.Tx, tenantID, excludedAccountID int64) (int64, error) {
	var count int64
	err := tx.QueryRow(ctx, `
		SELECT COUNT(DISTINCT tm.account_id)
		  FROM tenant_memberships tm
		  JOIN role_assignments ra
		    ON ra.account_id=tm.account_id
		   AND ra.tenant_id=tm.tenant_id
		   AND ra.scope_kind='tenant'
		  JOIN roles r ON r.id=ra.role_id
		 WHERE tm.tenant_id=$1
		   AND tm.account_id<>$2
		   AND tm.deleted_at IS NULL
		   AND tm.status='active'
		   AND ra.deleted_at IS NULL
		   AND (ra.expires_at IS NULL OR ra.expires_at > now())
		   AND COALESCE(ra.granted_reason, '') <> 'impersonate'
		   AND r.deleted_at IS NULL
		   AND r.code='tenant.admin'`,
		tenantID, excludedAccountID).Scan(&count)
	return count, err
}
