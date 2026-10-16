import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/group_member_picker.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/pages/contacts/contacts_directory_store.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

/// AddGroupMembersDialog 选择结果:按 kind 拆分,供 `POST /rooms/{uuid}/participants`。
class AddGroupMembersResult {
  const AddGroupMembersResult(
      {required this.accountUuids, required this.agentUuids});
  final List<String> accountUuids; // human account_uuid
  final List<String> agentUuids; // 数字员工 agent_uuid
  int get total => accountUuids.length + agentUuids.length;
}

/// P2.3a 添加群成员完整流程:弹选人框 → `POST /rooms/{uuid}/participants` → 刷新会话列表。
/// 返回 true 表示确实添加了成员(调用方据此再刷新群成员面板)。
///
/// [existingMemberIds] 是群内已有成员 id(human account_uuid + 数字员工 agent_uuid);
/// 这些成员在选择器里**不隐藏、置灰展示**,不可再次勾选。
Future<AddGroupMembersResult?> pickGroupMembers(
  BuildContext context, {
  required Set<String> existingMemberIds,
  bool mobile = false,
}) {
  if (mobile) {
    final theme = Theme.of(context);
    return Navigator.of(context, rootNavigator: true)
        .push<AddGroupMembersResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Theme(
          data: theme,
          child: AddGroupMembersDialog(
            existingMemberIds: existingMemberIds,
            mobile: true,
          ),
        ),
      ),
    );
  }
  return showDialog<AddGroupMembersResult>(
    context: context,
    builder: (_) => AddGroupMembersDialog(existingMemberIds: existingMemberIds),
  );
}

Future<bool> addGroupMembersFlow(
  BuildContext context,
  WidgetRef ref, {
  required String roomUuid,
  required Set<String> existingMemberIds,
}) async {
  if (roomUuid.isEmpty) {
    BotToast.showText(text: '缺少群 room_uuid,无法添加成员');
    return false;
  }
  final picked = await pickGroupMembers(
    context,
    existingMemberIds: existingMemberIds,
    mobile: PlatformUtils.isMobile,
  );
  if (picked == null || picked.total == 0) return false;
  try {
    await RoomsService().addGroupParticipants(
      roomUuid: roomUuid,
      accountUuids: picked.accountUuids,
      agentUuids: picked.agentUuids,
    );
    BotToast.showText(text: '已添加 ${picked.total} 位成员');
    // ignore: discarded_futures
    ref.read(conversationsProvider.notifier).refresh();
    return true;
  } catch (e) {
    BotToast.showText(text: '添加群成员失败: $e');
    return false;
  }
}

/// 添加群成员弹窗。视觉/交互与 [CreateGroupDialog] 的选人器保持一致(共用 group_member_picker)。
class AddGroupMembersDialog extends StatefulWidget {
  const AddGroupMembersDialog({
    super.key,
    this.existingMemberIds = const {},
    this.contactsService,
    this.mobile = false,
  });

  /// 群内已有成员 id(human account_uuid + 数字员工 agent_uuid),置灰展示、不可勾选。
  final Set<String> existingMemberIds;
  final ContactsService? contactsService;

  /// 移动端模式：渲染全屏 Scaffold 而非 Dialog。
  final bool mobile;

  @override
  State<AddGroupMembersDialog> createState() => _AddGroupMembersDialogState();
}

class _AddGroupMembersDialogState extends State<AddGroupMembersDialog> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = <String>{};
  final Map<String, ContactPerson> _byUuid = <String, ContactPerson>{};

  List<ContactPerson> _all = const []; // human
  List<ContactPerson> _agents = const []; // 数字员工
  List<ContactDepartment> _departments = const [];
  String _keyword = '';
  bool _loading = true;
  String? _error;

  ContactsService get _service =>
      widget.contactsService ?? const ContactsService();

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (widget.contactsService == null) {
      ContactsDirectoryStore.instance.notifier.removeListener(
        _onDirectoryChanged,
      );
    }
    super.dispose();
  }

  /// 测试注入假 [ContactsService] 时走原始直连路径; 真实使用(未注入)走
  /// [ContactsDirectoryStore]——跟 CreateGroupDialog 共用同一份数据(参见该文件
  /// `_loadContacts` 上的注释)。
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (widget.contactsService != null) {
        final flatDepartments = await _service.tree();
        final members = await _service.members(kind: 'human');
        final agents = await _service.members(kind: 'agent');
        _applySnapshotData(flatDepartments, members, agents);
        return;
      }
      ContactsDirectoryStore.instance.notifier.addListener(
        _onDirectoryChanged
      );
      final snapshot = await ContactsDirectoryStore.instance.ensureLoaded();
      _applySnapshotData(snapshot.departments, snapshot.humans, snapshot.agents);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载通讯录失败: $e';
        _loading = false;
      });
    }
  }

  void _onDirectoryChanged() {
    final snapshot = ContactsDirectoryStore.instance.current;
    if (snapshot == null || !mounted) return;
    _applySnapshotData(snapshot.departments, snapshot.humans, snapshot.agents);
  }

  void _applySnapshotData(
    List<ContactDepartment> flatDepartments,
    List<ContactPerson> members,
    List<ContactPerson> agents,
  ) {
    _byUuid
      ..clear()
      ..addEntries(members.map((m) => MapEntry(m.id, m)))
      ..addEntries(agents.map((m) => MapEntry(m.id, m)));
    if (!mounted) return;
    setState(() {
      _all = members;
      _agents = agents;
      _departments = buildContactDepartmentTree(flatDepartments);
      _loading = false;
    });
  }

  bool _isExisting(ContactPerson p) => widget.existingMemberIds.contains(p.id);

  /// 置灰判定:已在群内,或后端不允许邀请。
  bool _isDisabled(ContactPerson p) => _isExisting(p) || !p.canInviteToRoom;

  String? _disabledHint(ContactPerson p) {
    if (_isExisting(p)) return '已在群内';
    if (!p.canInviteToRoom) {
      return p.isAgent && p.source == 'platform' ? '需先启用' : '不可加群';
    }
    return null;
  }

  List<ContactPerson> get _filtered {
    final kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return _all;
    return _all
        .where((p) =>
            p.displayName.toLowerCase().contains(kw) ||
            p.subtitle.toLowerCase().contains(kw) ||
            p.departmentName.toLowerCase().contains(kw))
        .toList(growable: false);
  }

  List<ContactPerson> get _filteredAgents {
    final kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return _agents;
    return _agents
        .where((p) =>
            p.displayName.toLowerCase().contains(kw) ||
            p.subtitle.toLowerCase().contains(kw) ||
            p.positionLabel.toLowerCase().contains(kw))
        .toList(growable: false);
  }

  List<ContactPerson> get _selectedPeople => _selected
      .map((uuid) => _byUuid[uuid])
      .whereType<ContactPerson>()
      .toList(growable: false);

  void _toggle(ContactPerson p) {
    if (_isExisting(p)) {
      setState(() => _error = '${p.displayName} 已在群内');
      return;
    }
    if (!p.canInviteToRoom) {
      setState(() {
        _error = p.isAgent
            ? (p.source == 'platform'
                ? '${p.displayName} 是平台模板，启用后才能拉群'
                : '${p.displayName} 暂不允许加入群聊')
            : '${p.displayName} 不允许被拉入群聊';
      });
      return;
    }
    setState(() {
      if (_selected.contains(p.id)) {
        _selected.remove(p.id);
      } else {
        _selected.add(p.id);
      }
      _error = null;
    });
  }

  /// 部门下展示的人:human + agent, 按 departmentId 匹配(参见 CreateGroupDialog
  /// 同名方法的注释)。departmentId 为空(未注入 store 的测试夹具)按名字兜底。
  List<ContactPerson> _peopleForDepartment(ContactDepartment department) {
    final byId = [
      ..._all.where((p) => p.departmentId.isNotEmpty &&
          p.departmentId == department.id),
      ..._agents.where((p) => p.departmentId.isNotEmpty &&
          p.departmentId == department.id),
    ];
    if (byId.isNotEmpty) return byId;
    final name = department.name.trim();
    if (name.isEmpty) return const [];
    final humans = _all.where(
        (p) => p.departmentId.isEmpty && p.departmentName.trim() == name);
    final agents = _agents.where(
        (p) => p.departmentId.isEmpty && p.departmentName.trim() == name);
    return [...humans, ...agents].toList(growable: false);
  }

  /// subtree 内**可勾选**(非已存在 + 可邀请)的人,供部门 checkbox 用。
  List<ContactPerson> _selectableInSubtree(ContactDepartment department) {
    final result = <ContactPerson>[
      ..._peopleForDepartment(department).where((p) => !_isDisabled(p)),
    ];
    for (final child in department.children) {
      result.addAll(_selectableInSubtree(child));
    }
    final seen = <String>{};
    return result.where((p) => seen.add(p.id)).toList(growable: false);
  }

  bool _isDepartmentChecked(ContactDepartment department) {
    final people = _selectableInSubtree(department);
    return people.isNotEmpty &&
        people.every((person) => _selected.contains(person.id));
  }

  void _toggleDepartment(ContactDepartment department) {
    final people = _selectableInSubtree(department);
    if (people.isEmpty) return;
    final checked = people.every((person) => _selected.contains(person.id));
    setState(() {
      if (checked) {
        for (final person in people) {
          _selected.remove(person.id);
        }
      } else {
        for (final person in people) {
          _selected.add(person.id);
        }
      }
      _error = null;
    });
  }

  List<ContactPerson> get _ungrouped {
    final departmentNames = <String>{};
    void collect(ContactDepartment item) {
      departmentNames.add(item.name.trim());
      for (final child in item.children) {
        collect(child);
      }
    }

    for (final item in _departments) {
      collect(item);
    }
    return _all
        .where((p) => !departmentNames.contains(p.departmentName.trim()))
        .toList(growable: false);
  }

  AddGroupMembersResult _result() {
    final accountUuids = <String>[];
    final agentUuids = <String>[];
    for (final uuid in _selected) {
      final p = _byUuid[uuid];
      if (p != null && p.isAgent) {
        agentUuids.add(uuid);
      } else {
        accountUuids.add(uuid);
      }
    }
    return AddGroupMembersResult(
        accountUuids: accountUuids, agentUuids: agentUuids);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mobile) return _buildMobileScaffold(context);
    return UiContentDialog(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
            child: UiSheetHeader(
              title: '添加成员',
              subtitle: '从通讯录中选择要加入群聊的成员',
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F2F5)),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 11, child: _buildPickerPane()),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Color(0xFFF0F2F5),
                ),
                Expanded(flex: 10, child: _buildSelectedPane()),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F2F5)),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildMobileScaffold(BuildContext context) {
    final selected = _selectedPeople;
    final canSubmit = _selected.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: UiPageBar(
        title: '添加成员',
        onBack: () => Navigator.of(context).pop(),
        actions: [
          GestureDetector(
            onTap:
                canSubmit ? () => Navigator.of(context).pop(_result()) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                canSubmit ? '完成（${_selected.length}）' : '完成',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: canSubmit
                      ? const Color(0xFF2F80ED)
                      : const Color(0xFFB0B7C3),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: UiSearchField(
              hintText: '搜索联系人',
              fillColor: const Color(0xFFF3F4F6),
              showBorder: false,
              controller: _searchController,
              onChanged: (v) => setState(() => _keyword = v),
              onClear: () => setState(() => _keyword = ''),
            ),
          ),
          if (selected.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: selected.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final p = selected[i];
                  return _MobileSelectedChip(
                    person: p,
                    onRemove: () => _toggle(p),
                  );
                },
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFF53F3F), fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: Color(0xFFF0F2F5)),
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GroupMemberPicker(
                      departments: _departments,
                      agents: _agents,
                      searching: _keyword.trim().isNotEmpty,
                      searchHumans: _filtered,
                      searchAgents: _filteredAgents,
                      peopleForDepartment: _peopleForDepartment,
                      ungrouped: _ungrouped,
                      isSelected: (p) => _selected.contains(p.id),
                      isDepartmentChecked: _isDepartmentChecked,
                      onTogglePerson: _toggle,
                      onToggleDepartment: _toggleDepartment,
                      isDisabled: _isDisabled,
                      disabledHint: _disabledHint,
                      emptyHint: '暂无可添加成员',
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPickerPane() {
    return Container(
      color: const Color(0xFFFBFCFE),
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
      child: Column(
        children: [
          MemberSearchBox(
            controller: _searchController,
            onChanged: (value) => setState(() => _keyword = value),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : GroupMemberPicker(
                    departments: _departments,
                    agents: _agents,
                    searching: _keyword.trim().isNotEmpty,
                    searchHumans: _filtered,
                    searchAgents: _filteredAgents,
                    peopleForDepartment: _peopleForDepartment,
                    ungrouped: _ungrouped,
                    isSelected: (p) => _selected.contains(p.id),
                    isDepartmentChecked: _isDepartmentChecked,
                    onTogglePerson: _toggle,
                    onToggleDepartment: _toggleDepartment,
                    isDisabled: _isDisabled,
                    disabledHint: _disabledHint,
                    emptyHint: '暂无可添加成员',
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedPane() {
    final selected = _selectedPeople;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 30, 26, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '添加群成员',
                  style: TextStyle(
                    fontSize: 18,
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                _selected.isEmpty ? '选择联系人' : '已选择${_selected.length}个联系人',
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFF53F3F), fontSize: 12),
            ),
          ],
          const SizedBox(height: 18),
          Expanded(
            child: selected.isEmpty
                ? const Center(
                    child: Text(
                      '从左侧选择要添加的成员',
                      style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: selected.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final person = selected[index];
                      return SelectedMemberRow(
                        person: person,
                        onRemove: () => _toggle(person),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 26, 16),
      child: Row(
        children: [
          const Spacer(flex: 11),
          const SizedBox(width: 28),
          Expanded(
            flex: 10,
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFFF3F4F6),
                        foregroundColor: const Color(0xFF111827),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2F80ED),
                        disabledBackgroundColor: const Color(0xFFE5E7EB),
                        foregroundColor: Colors.white,
                        disabledForegroundColor: const Color(0xFF9CA3AF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(_result()),
                      child: Text(
                        '添加（${_selected.length}）',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileSelectedChip extends StatelessWidget {
  const _MobileSelectedChip({required this.person, required this.onRemove});
  final ContactPerson person;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRemove,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F4FF),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFD0DCFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              person.displayName.isEmpty ? '未命名' : person.displayName,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF2F80ED),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(CupertinoIcons.xmark,
                size: 12, color: Color(0xFF2F80ED)),
          ],
        ),
      ),
    );
  }
}
