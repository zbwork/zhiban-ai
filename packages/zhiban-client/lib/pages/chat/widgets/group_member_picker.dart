import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_core/contacts/contact_models.dart';

/// 群成员选择器共享组件(CreateGroupDialog / AddGroupMembersDialog 共用)。
///
/// 只抽两个弹框确实共用的左侧"搜索框 / 数字员工分区 / 组织树节点 / 联系人行 / checkbox /
/// 已选行"。**不**抽外层 Dialog、标题、footer、右侧已选区布局——这些两边各自保留。
/// 复用现有颜色 / 尺寸 / TextStyle / 边距,迁移后视觉不变,仅新增真实折叠 + 置灰能力。

const Color _kBlue = Color(0xFF2F80ED);
const Color _kText = Color(0xFF111827);
const Color _kGrey = Color(0xFF98A2B3);

/// 方形 checkbox。disabled = 置灰实心、不可勾。
class MemberSquareCheckBox extends StatelessWidget {
  const MemberSquareCheckBox({super.key, required this.checked, this.disabled = false});

  final bool checked;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    if (disabled) {
      return Container(
        width: 15,
        height: 15,
        decoration: BoxDecoration(
          color: const Color(0xFFF2F4F7),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: const Color(0xFFD0D5DD), width: 1.2),
        ),
        child: checked
            ? const Icon(CupertinoIcons.check_mark, size: 11, color: Color(0xFFB0B7C3))
            : null,
      );
    }
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        color: checked ? _kBlue : Colors.white,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: checked ? _kBlue : const Color(0xFF9CA3AF),
          width: 1.2,
        ),
      ),
      child: checked
          ? const Icon(CupertinoIcons.check_mark, size: 11, color: Colors.white)
          : null,
    );
  }
}

/// 搜索框(两弹框同款)。
class MemberSearchBox extends StatelessWidget {
  const MemberSearchBox({super.key, required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return UiSearchField(
      hintText: '搜索',
      controller: controller,
      onChanged: onChanged,
      fillColor: Colors.white,
    );
  }
}

/// 可折叠分区标题(数字员工)。chevron + 彩色 icon 盒 + 标题;点击切换展开。
class MemberSectionHeader extends StatelessWidget {
  const MemberSectionHeader({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.expanded,
    required this.onToggle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            Icon(
              expanded ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
              size: 10,
              color: const Color(0xFF9CA3AF),
            ),
            const SizedBox(width: 5),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(color: iconColor, borderRadius: BorderRadius.circular(5)),
              child: Icon(icon, size: 13, color: Colors.white),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: _kText, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 联系人行(human / 数字员工)。disabled → 置灰 + 不可勾(整行仍可 onTap 给提示)。
class MemberPickRow extends StatelessWidget {
  const MemberPickRow({
    super.key,
    required this.person,
    required this.checked,
    required this.selected,
    required this.level,
    required this.onTap,
    this.disabled = false,
    this.disabledHint,
  });

  final ContactPerson person;
  final bool checked;
  final bool selected;
  final int level;
  final VoidCallback onTap;
  final bool disabled;
  final String? disabledHint;

  @override
  Widget build(BuildContext context) {
    final titleColor = disabled
        ? _kGrey
        : (selected ? Colors.white : _kText);
    return Padding(
      padding: EdgeInsets.only(left: (level * 16).toDouble(), bottom: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: (selected && !disabled) ? _kBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              MemberSquareCheckBox(checked: checked, disabled: disabled),
              const SizedBox(width: 8),
              Opacity(
                opacity: disabled ? 0.45 : 1.0,
                child: ChatAvatar(
                  url: person.avatarUrl.isEmpty ? null : person.avatarUrl,
                  fallbackText: person.displayName,
                  kind: person.isAgent ? ChatAvatarKind.agent : ChatAvatarKind.user,
                  size: 22,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  person.displayName.isEmpty ? '未命名' : person.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: titleColor, fontWeight: FontWeight.w700),
                ),
              ),
              if (person.isAgent) ...[
                const SizedBox(width: 6),
                _AgentTag(
                  label: person.positionLabel.isNotEmpty ? person.positionLabel : '数字员工',
                  onSelected: selected && !disabled,
                ),
              ],
              if (disabled && (disabledHint ?? '').isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  disabledHint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? Colors.white70 : _kGrey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentTag extends StatelessWidget {
  const _AgentTag({required this.label, this.onSelected = false});

  final String label;
  final bool onSelected;

  @override
  Widget build(BuildContext context) {
    final fg = onSelected ? Colors.white : _kBlue;
    final bg = onSelected ? Colors.white.withValues(alpha: 0.22) : const Color(0xFFEAF2FE);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 右侧已选成员行。
class SelectedMemberRow extends StatelessWidget {
  const SelectedMemberRow({super.key, required this.person, required this.onRemove});

  final ContactPerson person;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          ChatAvatar(
            url: person.avatarUrl.isEmpty ? null : person.avatarUrl,
            fallbackText: person.displayName,
            kind: person.isAgent ? ChatAvatarKind.agent : ChatAvatarKind.user,
            size: 26,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              person.displayName.isEmpty ? '未命名' : person.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _kText, fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          _RemoveButton(onPressed: onRemove),
        ],
      ),
    );
  }
}

/// 移除按钮:hover 只变图标颜色(灰→深灰),不带 tooltip。
class _RemoveButton extends StatefulWidget {
  const _RemoveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: Icon(
              CupertinoIcons.xmark,
              size: 16,
              color: _hovered ? const Color(0xFF5B9BF1) : const Color(0xFF6B7280),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左侧选择器主体:数字员工分区(可折叠) + 组织树(真实展开/折叠,默认只展开顶层) + 未分组。
/// 搜索态显示扁平结果。expand 状态属纯视图,内部自管;选中状态由外层弹框持有(驱动右侧 + 提交)。
class GroupMemberPicker extends StatefulWidget {
  const GroupMemberPicker({
    super.key,
    required this.departments,
    required this.agents,
    required this.searching,
    required this.searchHumans,
    required this.searchAgents,
    required this.peopleForDepartment,
    required this.ungrouped,
    required this.isSelected,
    required this.isDepartmentChecked,
    required this.onTogglePerson,
    required this.onToggleDepartment,
    this.isDisabled,
    this.disabledHint,
    this.agentSectionTitle = '数字员工',
    this.emptyHint = '暂无可选成员',
  });

  final List<ContactDepartment> departments;

  /// 独立"数字员工"分区:全部可见数字员工(快速选择)。
  final List<ContactPerson> agents;

  final bool searching;
  final List<ContactPerson> searchHumans;
  final List<ContactPerson> searchAgents;

  /// 某部门下展示的人(human + 该部门 departmentName 命中的数字员工)。
  final List<ContactPerson> Function(ContactDepartment) peopleForDepartment;

  /// 不属于任何已知部门的 human(兜底)。
  final List<ContactPerson> ungrouped;

  final bool Function(ContactPerson) isSelected;
  final bool Function(ContactDepartment) isDepartmentChecked;
  final ValueChanged<ContactPerson> onTogglePerson;
  final ValueChanged<ContactDepartment> onToggleDepartment;

  /// 置灰判定(已在群内 / 不可邀请);返回 true → checkbox 灰、不进右侧已选。
  final bool Function(ContactPerson)? isDisabled;

  /// 置灰原因副标(如"已在群内"/"需先启用")。
  final String? Function(ContactPerson)? disabledHint;

  final String agentSectionTitle;
  final String emptyHint;

  @override
  State<GroupMemberPicker> createState() => _GroupMemberPickerState();
}

class _GroupMemberPickerState extends State<GroupMemberPicker> {
  final Set<String> _expandedDeptIds = <String>{};
  bool _agentExpanded = true;
  bool _expandInited = false;

  @override
  void initState() {
    super.initState();
    _ensureDefaultExpand();
  }

  @override
  void didUpdateWidget(covariant GroupMemberPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 部门数据异步到达后初始化默认展开(只展开顶层)。
    if (!_expandInited && widget.departments.isNotEmpty) {
      _ensureDefaultExpand();
    }
  }

  /// 默认:顶层部门展开,二级及以下折叠。
  void _ensureDefaultExpand() {
    if (widget.departments.isEmpty) return;
    _expandedDeptIds
      ..clear()
      ..addAll(widget.departments.map((d) => d.id));
    _expandInited = true;
  }

  bool _disabled(ContactPerson p) => widget.isDisabled?.call(p) ?? false;

  /// subtree(本部门直属人员 + 本部门数字员工 + 所有子部门及其成员)内是否存在可选成员
  /// (即 `isDisabled(person)==false`)。用于:全是 existing/不可加群时,部门 checkbox 置灰。
  bool _hasSelectableInSubtree(ContactDepartment department) {
    for (final p in widget.peopleForDepartment(department)) {
      if (!_disabled(p)) return true;
    }
    for (final child in department.children) {
      if (_hasSelectableInSubtree(child)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.searching) {
      return _buildSearchList();
    }
    final hasAgents = widget.agents.isNotEmpty;
    final hasDepts = widget.departments.isNotEmpty;
    final hasUngrouped = widget.ungrouped.isNotEmpty;
    if (!hasAgents && !hasDepts && !hasUngrouped) {
      return Center(
        child: Text(widget.emptyHint, style: const TextStyle(color: _kGrey, fontSize: 13)),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (hasAgents) ...[
          MemberSectionHeader(
            key: const ValueKey('member-agent-section-header'),
            icon: Icons.smart_toy_rounded,
            iconColor: const Color(0xFF5B9BF1),
            title: widget.agentSectionTitle,
            expanded: _agentExpanded,
            onToggle: () => setState(() => _agentExpanded = !_agentExpanded),
          ),
          const SizedBox(height: 4),
          if (_agentExpanded)
            for (final agent in widget.agents) _personRow(agent, level: 1),
          const SizedBox(height: 14),
        ],
        for (final department in widget.departments) _deptNode(department, 0),
        for (final person in widget.ungrouped) _personRow(person, level: 1),
      ],
    );
  }

  Widget _buildSearchList() {
    final agents = widget.searchAgents;
    final humans = widget.searchHumans;
    if (agents.isEmpty && humans.isEmpty) {
      return Center(
        child: Text(widget.emptyHint, style: const TextStyle(color: _kGrey, fontSize: 13)),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final agent in agents) _personRow(agent, level: 1),
        for (final person in humans) _personRow(person, level: 1),
      ],
    );
  }

  Widget _personRow(ContactPerson person, {required int level}) {
    final disabled = _disabled(person);
    return MemberPickRow(
      person: person,
      checked: widget.isSelected(person),
      selected: widget.isSelected(person),
      level: level,
      disabled: disabled,
      disabledHint: disabled ? widget.disabledHint?.call(person) : null,
      onTap: () => widget.onTogglePerson(person),
    );
  }

  Widget _deptNode(ContactDepartment department, int level) {
    final people = widget.peopleForDepartment(department);
    final expandable = department.children.isNotEmpty || people.isNotEmpty;
    final expanded = _expandedDeptIds.contains(department.id);
    final checked = widget.isDepartmentChecked(department);
    // subtree 内无可选成员(全 existing/不可加群)→ checkbox 置灰、点击不勾选;
    // 但展开/折叠不受影响(仍可展开看里面的置灰成员)。
    final selectable = _hasSelectableInSubtree(department);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: (level * 16).toDouble(), bottom: 1),
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                // checkbox 区:单独 tap → 勾选/取消该部门 subtree(不展开)。
                // 无可选成员时置灰、tap 无效(不触发 onToggleDepartment)。
                GestureDetector(
                  key: ValueKey('dept-cb-${department.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: selectable ? () => widget.onToggleDepartment(department) : null,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: MemberSquareCheckBox(checked: checked, disabled: !selectable),
                  ),
                ),
                // chevron + 文件夹 + 部门名:tap → 只切换展开/折叠。
                Expanded(
                  child: InkWell(
                    onTap: expandable
                        ? () => setState(() {
                              if (expanded) {
                                _expandedDeptIds.remove(department.id);
                              } else {
                                _expandedDeptIds.add(department.id);
                              }
                            })
                        : null,
                    borderRadius: BorderRadius.circular(4),
                    child: Row(
                      children: [
                        Icon(
                          expanded
                              ? CupertinoIcons.chevron_down
                              : CupertinoIcons.chevron_right,
                          size: 10,
                          color: const Color(0xFF9CA3AF),
                        ),
                        const SizedBox(width: 5),
                        const Icon(CupertinoIcons.folder_fill, size: 18, color: Color(0xFF4B90E8)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            department.name.isEmpty ? '未命名部门' : department.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: _kText,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          for (final person in people) _personRow(person, level: level + 1),
          for (final child in department.children) _deptNode(child, level + 1),
        ],
      ],
    );
  }
}
