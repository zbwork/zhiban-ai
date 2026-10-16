import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/chat/widgets/group_member_picker.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/pages/contacts/contacts_directory_store.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_ui/widgets/ui_form.dart';
import 'package:zhiban_ui/widgets/ui_field_style.dart';
import 'package:zhiban_ui/widgets/ui_tap_surface.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 发起人由后端自动加入；还需至少 2 个受邀参与者才构成 3 人及以上群聊。
bool hasMinimumGroupInvitees(int inviteeCount) => inviteeCount >= 2;

/// P2.3a 新建群聊弹窗:从通讯录 human + 数字员工 多选,提交调 `POST /rooms`
/// (roomKind=group)建群,成功 pop 返回 [GroupRoom]。取消返回 null。
class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog(
      {super.key,
      this.contactsService,
      this.currentAccountUuid,
      this.mobile = false,
      this.preselectedUuids = const {}});

  /// 可注入(测试);默认 const ContactsService()。
  final ContactsService? contactsService;

  /// 当前登录账号 uuid。未显式传入时从本地登录缓存读取;用于禁选"自己"。
  final String? currentAccountUuid;

  /// 移动端模式：渲染全屏 Scaffold 而非 Dialog。
  final bool mobile;

  /// 从单聊(人↔人或人↔数字员工)顶栏"加人"进入时,预选中对方 uuid。
  final Set<String> preselectedUuids;

  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = <String>{}; // 选中的 account/agent uuid
  final Map<String, ContactPerson> _byUuid = <String, ContactPerson>{};

  List<ContactPerson> _all = const []; // human 成员
  List<ContactPerson> _agents = const []; // 数字员工(kind=agent)
  List<ContactDepartment> _departments = const [];
  String _keyword = '';
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  String _currentAccountUuid = '';

  ContactsService get _service =>
      widget.contactsService ?? const ContactsService();

  @override
  void initState() {
    super.initState();
    _currentAccountUuid = (widget.currentAccountUuid ?? '').trim();
    _selected.addAll(widget.preselectedUuids);
    // ignore: discarded_futures
    _loadContacts();
    if (_currentAccountUuid.isEmpty) {
      // ignore: discarded_futures
      _loadCurrentAccountUuid();
    }
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

  /// 测试注入假 [ContactsService] 时走原始直连路径(不进共享缓存, 保持用例可控);
  /// 真实使用(未注入)一律走 [ContactsDirectoryStore]——通讯录 / 发起群聊 /
  /// 加群成员共用同一份数据, 打开时后台重新拉一遍, 内容有差异就更新展示。
  Future<void> _loadContacts() async {
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
      _applySnapshotData(
          snapshot.departments, snapshot.humans, snapshot.agents);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载通讯录失败: $e';
          _loading = false;
        });
      }
    }
  }

  /// store 后台 refresh() 拉到不同内容时触发——弹窗开着的过程中org数据变了
  /// (比如刚好有人被挪部门),同步刷新左侧树/右侧已选不受影响(选中态按 uuid 存)。
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
    if (mounted) {
      setState(() {
        _all = members;
        _agents = agents;
        _departments = buildContactDepartmentTree(flatDepartments);
        _loading = false;
      });
    }
  }

  Future<void> _loadCurrentAccountUuid() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uuid = extractCurrentAccountUuidFromAccountCache(
        prefs.getString(AppConfig.storageAccountInfoKey),
      );
      if (!mounted || uuid.isEmpty) return;
      setState(() {
        _currentAccountUuid = uuid;
        _selected.remove(uuid);
      });
    } catch (_) {
      // 取不到本地账号只影响"自己禁选"兜底, 不阻断弹窗打开。
    }
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

  /// 搜索模式下匹配的数字员工。
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

  List<ContactPerson> get _selectedPeople {
    return _selected
        .map((uuid) => _byUuid[uuid])
        .whereType<ContactPerson>()
        .where((person) => !_isSelf(person))
        .toList(growable: false);
  }

  /// 默认群名:发起人(自己)+ 被邀请人拼接(最多前 3 个 + 等 N 人)。发起人是
  /// 群主、后端会自动入群, 名字理应算进默认群名, 只拼被邀请人会漏掉自己
  /// (2026-08-19 真实反馈:4 人群"灵犀、测试号、超级管理员"少了群主"刘明")。
  String _defaultTitle() {
    final selfName = _byUuid[_currentAccountUuid]?.displayName.trim() ?? '';
    final names = [
      if (selfName.isNotEmpty) selfName,
      ..._selectedPeople.map((p) => p.displayName.trim()),
    ].where((n) => n.isNotEmpty).toList();
    if (names.isEmpty) return '';
    if (names.length <= 3) return names.join('、');
    return '${names.take(3).join('、')}等${names.length}人';
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // 按 kind 拆分 human / 数字员工（后端 participants[].kind 区分）。
    final humanUuids = <String>[];
    final agentUuids = <String>[];
    for (final uuid in _selected) {
      final p = _byUuid[uuid];
      if (p != null && _isSelf(p)) continue;
      if (p != null && p.isAgent) {
        agentUuids.add(uuid);
      } else {
        humanUuids.add(uuid);
      }
    }
    // 发起人自动入群；human / agent 等价计数，总成员数至少 3。
    if (!hasMinimumGroupInvitees(humanUuids.length + agentUuids.length)) {
      setState(() => _error = '群聊至少需要 3 位成员（包含发起人），请再选择成员');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final room = await RoomsService().createGroup(
        title: _defaultTitle(),
        participantAccountUuids: humanUuids,
        agentUuids: agentUuids,
      );
      if (mounted) Navigator.of(context).pop(room);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '创建群聊失败: $e';
          _submitting = false;
        });
      }
    }
  }

  void _toggle(ContactPerson p) {
    if (_isSelf(p)) {
      setState(() => _error = '不能选择自己，发起人会自动加入群聊');
      return;
    }
    // canInviteToRoom=false 的 contact 不可勾选 (后端口径同源, 提交会被 CanCreateGroup 拒)。
    if (!p.canInviteToRoom) {
      setState(() {
        _error = p.isAgent
            ? (p.source == 'platform'
                ? '${p.displayName} 是平台模板，启用为本租户的数字员工后才能拉群'
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

  bool _isSelf(ContactPerson p) {
    return p.isHuman &&
        _currentAccountUuid.isNotEmpty &&
        p.id == _currentAccountUuid;
  }

  bool _isSelectable(ContactPerson p) => p.canInviteToRoom && !_isSelf(p);

  /// 部门下展示的人:human + agent, 按 departmentId 匹配(后端 `/contacts` 一直
  /// 下发这个字段——之前按 departmentName 字符串匹配, 同名部门会互相串人、
  /// 也没法区分"系统运维部"下两个不同的"运维研发团队")。
  /// departmentId 为空(未注入 store 的测试夹具)按名字兜底, 保持旧用例不用改。
  List<ContactPerson> _peopleForDepartment(ContactDepartment department) {
    final byId = [
      ..._all.where(
          (p) => p.departmentId.isNotEmpty && p.departmentId == department.id),
      ..._agents.where(
          (p) => p.departmentId.isNotEmpty && p.departmentId == department.id),
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

  /// subtree 内**可勾选**的人(human + 数字员工),供部门 checkbox 用。
  List<ContactPerson> _selectableInSubtree(ContactDepartment department) {
    final result = <ContactPerson>[
      ..._peopleForDepartment(department).where(_isSelectable),
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

  /// 不属于任何已知部门的 human(兜底)。
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

  @override
  Widget build(BuildContext context) {
    if (widget.mobile) return _buildMobileScaffold(context);
    return UiContentDialog(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
            child: UiSheetHeader(
              title: '发起群聊',
              subtitle: '从通讯录中选择群成员',
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
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedPeople;
    final canSubmit = !_submitting && selected.isNotEmpty;
    return Scaffold(
      backgroundColor: UiFormStyle.pageBackground(scheme),
      appBar: UiPageBar(
        title: '发起群聊',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: UiSearchField(
                hintText: '搜索联系人',
                fillColor: scheme.surface,
                showBorder: false,
                controller: _searchController,
                onChanged: (v) => setState(() => _keyword = v),
                onClear: () => setState(() => _keyword = ''),
              ),
            ),
            if (selected.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: (MediaQuery.textScalerOf(context).scale(13) * 1.4 + 16)
                    .clamp(44.0, double.infinity),
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
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : Container(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: UiFieldStyle.enabledBorderColor(scheme)),
                      ),
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
                        isDisabled: (p) => !_isSelectable(p),
                        disabledHint: (p) {
                          if (_isSelf(p)) return '自己';
                          return p.isAgent && p.source == 'platform'
                              ? '需先启用'
                              : '不可加群';
                        },
                      ),
                    ),
            ),
            UiFormFooter(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('已选 ${selected.length} 位成员',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  UiFormActions(
                      primaryLabel: '完成',
                      onPrimary: canSubmit ? _submit : null,
                      busy: _submitting),
                ],
              ),
            ),
          ],
        ),
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
                    isDisabled: (p) => !_isSelectable(p),
                    disabledHint: (p) {
                      if (_isSelf(p)) return '自己';
                      return p.isAgent && p.source == 'platform'
                          ? '需先启用'
                          : '不可加群';
                    },
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
                  '发起群聊',
                  style: TextStyle(
                    fontSize: 18,
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                selected.isEmpty ? '选择联系人' : '已选择${selected.length}个联系人',
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
                      '从左侧选择群成员',
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
    final canSubmit = !_submitting && _selectedPeople.isNotEmpty;
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
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
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
                      onPressed: canSubmit ? _submit : null,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CupertinoActivityIndicator(
                                  color: Colors.white),
                            )
                          : const Text(
                              '完成',
                              style: TextStyle(
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
    final scheme = Theme.of(context).colorScheme;
    return UiTapSurface(
      onTap: onRemove,
      borderRadius: BorderRadius.circular(20),
      color: scheme.primaryContainer,
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.7),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
                child: Text(
              person.displayName.isEmpty ? '未命名' : person.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w500,
              ),
            )),
            const SizedBox(width: 4),
            Icon(CupertinoIcons.xmark,
                size: 12, color: scheme.onPrimaryContainer),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
String extractCurrentAccountUuidFromAccountCache(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return '';
    final root = decoded.cast<String, dynamic>();
    final account = (root['account'] is Map)
        ? (root['account'] as Map).cast<String, dynamic>()
        : root;
    return _firstNonEmpty([
      account['uuid'],
      account['account_uuid'],
      account['accountUuid'],
      account['accountNo'],
      root['uuid'],
      root['account_uuid'],
      root['accountUuid'],
    ]);
  } catch (_) {
    return '';
  }
}

String _firstNonEmpty(Iterable<Object?> values) {
  for (final value in values) {
    final text = (value ?? '').toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}
