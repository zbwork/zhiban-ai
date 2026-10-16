import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contacts_constants.dart';
import 'package:zhiban_client/pages/contacts/contacts_shared_widgets.dart';
import 'package:zhiban_client/pages/contacts/contacts_skeletons.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_tree_folder_tile.dart';
import 'package:zhiban_ui/widgets/ui_tree_leaf_tile.dart';

const _sidebarIndentStep = 12.0;

class ContactsSidebar extends ConsumerStatefulWidget {
  const ContactsSidebar({
    super.key,
    required this.selectedPersonId,
    required this.selectedAgentId,
    required this.selectedAgentFilter,
    required this.onAgentFilterSelected,
    required this.onAgentSelected,
    required this.onDepartmentSelected,
    required this.onHumanSelected,
  });

  final String? selectedPersonId;
  final String? selectedAgentId;
  final AgentListFilter selectedAgentFilter;
  final ValueChanged<AgentListFilter> onAgentFilterSelected;
  final ValueChanged<ContactAgent> onAgentSelected;
  final ValueChanged<ContactDepartment> onDepartmentSelected;
  final ValueChanged<ContactPerson> onHumanSelected;

  @override
  ConsumerState<ContactsSidebar> createState() => _ContactsSidebarState();
}

class _ContactsSidebarState extends ConsumerState<ContactsSidebar> {
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  /// 搜索防抖：keyword provider 被成员 / 数字员工 / 各展开部门的 family
  /// provider 同时 watch，逐键写入会让一次按键触发整轮网络请求（请求风暴）。
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      ref.read(contactsKeywordProvider.notifier).state = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tree = ref.watch(contactTreeProvider);
    final agents = ref.watch(contactAgentsProvider);
    final visibleDeptIds =
        ref.watch(contactSearchVisibleDepartmentIdsProvider).value;
    final agentsSnapshot = agents.value;
    final showAgentsSection = !agents.hasValue ||
        agentsSnapshot!.personal.isNotEmpty ||
        agentsSnapshot.enterprise.isNotEmpty ||
        agentsSnapshot.platform.isNotEmpty;
    final visibleDepartments = tree.value == null
        ? null
        : filterVisibleDepartments(tree.value!, visibleDeptIds);
    final showDeptSection =
        visibleDepartments == null || visibleDepartments.isNotEmpty;
    return Container(
      width: 280,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
        boxShadow: [
          BoxShadow(
            color: Color(0x080F172A),
            blurRadius: 22,
            offset: Offset(10, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: UiSearchField(
              hintText: '快速搜索人员、部门...',
              fillColor: const Color(0xFFF3F4F7),
              showBorder: false,
              borderRadius: 10,
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showAgentsSection) ...[
                    const SizedBox(height: 4),
                    AgentSidebarTree(
                      selectedAgentId: widget.selectedAgentId,
                      selectedFilter: widget.selectedAgentFilter,
                      agents: agents,
                      onFilterSelected: widget.onAgentFilterSelected,
                      onAgentSelected: widget.onAgentSelected,
                    ),
                  ],
                  if (showAgentsSection && showDeptSection)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 10),
                      child: Divider(height: 1, color: Color(0xFFE2E8F0)),
                    ),
                  if (showDeptSection) ...[
                    const SidebarSectionLabel('组织架构'),
                    tree.when(
                       skipLoadingOnReload: true,
                       skipError: true,
                      data: (items) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 12, 18),
                        child: Column(children: [
                          for (final item in visibleDepartments!)
                            DepartmentTreeFolder(
                              key: ValueKey(item.id),
                              department: item,
                              selectedId: ref
                                  .watch(selectedContactDepartmentProvider)
                                  ?.id,
                              selectedPersonId: widget.selectedPersonId,
                              onSelected: widget.onDepartmentSelected,
                              onHumanSelected: widget.onHumanSelected,
                            ),
                        ]),
                      ),
                      loading: () => const ContactsTreeSkeleton(shrinkWrap: true),
                      error: (error, _) => const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "数字员工"树：与"组织架构"结构对称——静态分组标题（复用
/// [SidebarSectionLabel]，与"组织架构"文字展示一致）+ 常驻子行
/// （个人创建的数字员工叶子行 + "企业创建的"文件夹），平台员工与组织员工
/// 共用该紧凑文件夹；数字员工页另行按四种来源分栏。这里不再有整体的
/// 选中/展开收起态。
class AgentSidebarTree extends StatelessWidget {
  const AgentSidebarTree({
    super.key,
    required this.selectedAgentId,
    required this.selectedFilter,
    required this.agents,
    required this.onFilterSelected,
    required this.onAgentSelected,
    this.allowExpand = true,
  });

  final String? selectedAgentId;
  final AgentListFilter selectedFilter;
  final AsyncValue<ContactAgentsSnapshot> agents;
  final ValueChanged<AgentListFilter> onFilterSelected;
  final ValueChanged<ContactAgent> onAgentSelected;

  /// 移动端 tap 即跳转到子页面，行内展开没有意义，传 false 关掉；
  /// 桌面侧栏保持原样。
  final bool allowExpand;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SidebarSectionLabel('数字员工'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: agents.when(
            data: (snapshot) => Column(
              children: [
                for (final agent in snapshot.personal)
                  _AgentSidebarTile(
                    agent: agent,
                    depth: 0,
                    showExpandSlot: allowExpand,
                    leadingGap: allowExpand ? 8 : 6,
                    selected: selectedAgentId == agent.id,
                    onTap: () => onAgentSelected(agent),
                  ),
                if (snapshot.enterprise.isNotEmpty ||
                    snapshot.platform.isNotEmpty)
                  AgentFolderExpander(
                    label: '企业创建的',
                    selected: selectedAgentId == null &&
                        selectedFilter == AgentListFilter.enterprise,
                    onSelected: () =>
                        onFilterSelected(AgentListFilter.enterprise),
                    allowExpand: allowExpand,
                    children: [
                      for (final agent in [
                        ...snapshot.enterprise,
                        ...snapshot.platform,
                      ])
                        _AgentSidebarTile(
                          agent: agent,
                          depth: 1,
                          showExpandSlot: allowExpand,
                          leadingGap: allowExpand ? 8 : 6,
                          selected: selectedAgentId == agent.id,
                          onTap: () => onAgentSelected(agent),
                        ),
                    ],
                  ),
              ],
            ),
            loading: () => const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 4),
              child: CupertinoActivityIndicator(radius: 8),
            ),
            error: (error, _) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// "企业创建的"数字员工文件夹：单层非递归，子项已由调用方解析为 [children]。
/// 与递归+异步加载的 [DepartmentTreeFolder] 对应，共用 [UiTreeFolderTile] 渲染。
class AgentFolderExpander extends StatefulWidget {
  const AgentFolderExpander({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    required this.children,
    this.allowExpand = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final List<Widget> children;

  /// 移动端 tap 即跳转到子页面，行内展开没有意义（甚至会闪一下就被导航盖掉），
  /// 传 false 关掉；桌面侧栏保持原样（tap = 选中 + 行内展开二选一都要）。
  final bool allowExpand;

  @override
  State<AgentFolderExpander> createState() => _AgentFolderExpanderState();
}

class _AgentFolderExpanderState extends State<AgentFolderExpander> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        UiTreeFolderTile(
          margin: EdgeInsetsGeometry.zero,
          label: widget.label,
          selected: widget.selected,
          expanded: widget.allowExpand ? _expanded : null,
          showExpandSlot: widget.allowExpand,
          selectedColor: contactsSidebarAccentColor,
          unselectedColor: contactsSidebarPrimaryTextColor,
          selectedBgColor: contactsSidebarSelectedBgColor,
          fontSize: contactsSidebarFolderTextSize,
          onTap: () {
            widget.onSelected();
            if (widget.allowExpand) setState(() => _expanded = !_expanded);
          },
        ),
        if (widget.allowExpand && _expanded) ...widget.children,
      ],
    );
  }
}

class _AgentSidebarTile extends StatelessWidget {
  const _AgentSidebarTile({
    required this.agent,
    required this.depth,
    required this.showExpandSlot,
    required this.leadingGap,
    required this.selected,
    required this.onTap,
  });

  final ContactAgent agent;
  final int depth;
  final bool showExpandSlot;
  final double leadingGap;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return UiTreeLeafTile(
      leading: ContactAvatar(
          url: agent.avatarUrl, name: agent.displayName, size: 20),
      title: agent.displayName,
      selected: selected,
      onTap: onTap,
      margin: EdgeInsets.only(left: depth * _sidebarIndentStep, bottom: 0),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      borderRadius: 8,
      selectedColor: contactsSidebarAccentColor,
      unselectedColor: contactsSidebarPrimaryTextColor,
      selectedBgColor: Colors.transparent,
      fontSize: contactsSidebarTextSize,
      showExpandSlot: showExpandSlot,
      leadingGap: leadingGap,
    );
  }
}

/// 组织架构部门文件夹：递归渲染子部门 + 异步加载本部门成员。
/// 与单层非递归的 [AgentFolderExpander] 对应，共用 [UiTreeFolderTile] 渲染。
class DepartmentTreeFolder extends ConsumerStatefulWidget {
  const DepartmentTreeFolder({
    super.key,
    required this.department,
    required this.selectedId,
    required this.selectedPersonId,
    required this.onSelected,
    required this.onHumanSelected,
    this.depth = 0,
    this.allowExpand = true,
  });

  final ContactDepartment department;
  final String? selectedId;
  final String? selectedPersonId;
  final ValueChanged<ContactDepartment> onSelected;
  final ValueChanged<ContactPerson> onHumanSelected;
  final int depth;

  /// 移动端 tap 即跳转到子页面，行内展开没有意义，传 false 关掉；
  /// 桌面侧栏保持原样。
  final bool allowExpand;

  @override
  ConsumerState<DepartmentTreeFolder> createState() =>
      _DepartmentTreeFolderState();
}

class _DepartmentTreeFolderState extends ConsumerState<DepartmentTreeFolder> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final department = widget.department;
    final depth = widget.depth;
    final selectedId = widget.selectedId;
    final selectedPersonId = widget.selectedPersonId;
    final onSelected = widget.onSelected;
    final onHumanSelected = widget.onHumanSelected;
    final allowExpand = widget.allowExpand;
    final selected = selectedId == department.id;
    // 可展开 = 有子部门 或 有成员(human/agent). children 只含子部门, 成员靠 tree 接口的计数判断.
    final hasContent = department.children.isNotEmpty ||
        department.humanCount > 0 ||
        department.agentCount > 0;
    // members = humans + agents (provider 不再写死 kind=human, 数字员工随成员一起进树).
    final members = ref.watch(contactDepartmentMembersProvider(department.id));
    final visibleDeptIds =
        ref.watch(contactSearchVisibleDepartmentIdsProvider).value;
    final searching = ref.watch(contactsKeywordProvider).trim().isNotEmpty;
    final effectiveExpanded = _expanded || (allowExpand && searching);
    return Column(
      children: [
        UiTreeFolderTile(
          label: department.name,
          selected: selected,
          margin: EdgeInsets.only(left: depth * _sidebarIndentStep, bottom: 0),
          expanded: allowExpand && hasContent ? effectiveExpanded : null,
          showExpandSlot: allowExpand,
          selectedColor: contactsSidebarAccentColor,
          unselectedColor: contactsSidebarPrimaryTextColor,
          selectedBgColor: contactsSidebarSelectedBgColor,
          fontSize: contactsSidebarFolderTextSize,
          onTap: () {
            onSelected(department);
            if (allowExpand && hasContent) {
              setState(() => _expanded = !effectiveExpanded);
            }
          },
        ),
        if (allowExpand && effectiveExpanded) ...[
          members.when(
            data: (items) => Column(
              children: [
                for (final item in items)
                  _DepartmentHumanTile(
                    person: item,
                    depth: depth + 1,
                    selected: selectedPersonId == item.id,
                    onTap: () => onHumanSelected(item),
                  ),
              ],
            ),
            loading: () => Padding(
              padding: EdgeInsets.only(left: (depth + 1) * 12.0 + 6, bottom: 4),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CupertinoActivityIndicator(radius: 7),
                ),
              ),
            ),
            error: (_, __) => const SizedBox.shrink(),
          ),
          for (final child
              in filterVisibleDepartments(department.children, visibleDeptIds))
            DepartmentTreeFolder(
              key: ValueKey(child.id),
              department: child,
              selectedId: selectedId,
              selectedPersonId: selectedPersonId,
              onSelected: onSelected,
              onHumanSelected: onHumanSelected,
              depth: depth + 1,
              allowExpand: allowExpand,
            ),
        ],
      ],
    );
  }
}

class _DepartmentHumanTile extends StatelessWidget {
  const _DepartmentHumanTile({
    required this.person,
    required this.depth,
    required this.selected,
    required this.onTap,
  });

  final ContactPerson person;
  final int depth;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return UiTreeLeafTile(
      leading: ContactAvatar(
          url: person.avatarUrl, name: person.displayName, size: 20),
      title: person.displayName,
      selected: selected,
      onTap: onTap,
      margin: EdgeInsets.only(left: depth * _sidebarIndentStep, bottom: 0),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      borderRadius: 8,
      selectedColor: contactsSidebarAccentColor,
      unselectedColor: contactsSidebarPrimaryTextColor,
      selectedBgColor: Colors.transparent,
      fontSize: contactsSidebarTextSize,
    );
  }
}

class SidebarSectionLabel extends StatelessWidget {
  const SidebarSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 0, 5),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: contactsSidebarSectionLabelTextSize,
          color: Color(0xFF9AA1AE),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class SidebarError extends StatelessWidget {
  const SidebarError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12),
      ),
    );
  }
}
