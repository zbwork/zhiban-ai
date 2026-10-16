package contacts

// ResolveMask 把成员级 metadata.field_mask 与租户 policy 默认合并成最终 FieldMask。
//
// 规则 (M2 §3.4): 成员级 优先 policy 默认, 缺省/非法值回退到 policy。
func ResolveMask(memberMask map[string]FieldVisibility, policy ContactPolicy) FieldMask {
	defaults := policy.PolicyDefaults()
	out := defaults
	if v, ok := memberMask["phone"]; ok && v.IsValid() {
		out.Phone = v
	}
	if v, ok := memberMask["email"]; ok && v.IsValid() {
		out.Email = v
	}
	if v, ok := memberMask["title"]; ok && v.IsValid() {
		out.Title = v
	}
	return out
}

// FieldVisible 在 caller 视角下判断单个字段是否对外可见。
//
// 参数:
//
//	v             字段可见性 (来自 ResolveMask)
//	sameAccount   caller 与 target 是否同一人
//	sameDept      caller 与 target 是否同一部门 (按 departments.id 等值比较, 不做祖先匹配)
func FieldVisible(v FieldVisibility, sameAccount, sameDept bool) bool {
	switch v {
	case FieldAll:
		return true
	case FieldDepartment:
		return sameAccount || sameDept
	case FieldSelf:
		return sameAccount
	case FieldHidden:
		return false
	}
	return false
}

// ApplyMask 把 mask 应用到 raw 字段, 返回客户端可见的 HumanContactFields 与 subtitle。
//
// raw 是数据库原值 (可能为空); subtitleRaw 是 tenant_memberships.title (可被 metadata.position_label_override 覆盖)。
func ApplyMask(rawPhone, rawEmail, subtitleRaw string, mask FieldMask, sameAccount, sameDept bool) (HumanContactFields, string) {
	out := HumanContactFields{}
	if rawPhone != "" && FieldVisible(mask.Phone, sameAccount, sameDept) {
		out.Phone = rawPhone
	}
	if rawEmail != "" && FieldVisible(mask.Email, sameAccount, sameDept) {
		out.Email = rawEmail
	}
	subtitle := ""
	if subtitleRaw != "" && FieldVisible(mask.Title, sameAccount, sameDept) {
		subtitle = subtitleRaw
	}
	return out, subtitle
}
