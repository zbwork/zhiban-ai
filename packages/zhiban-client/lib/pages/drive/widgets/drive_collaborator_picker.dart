import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_ui/widgets/ui_field_style.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

Future<List<ContactPerson>?> showDriveCollaboratorPicker(
  BuildContext context, {
  required List<ContactPerson> initialSelected,
  Set<String> disabledIds = const <String>{},
}) {
  return showDialog<List<ContactPerson>>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    useSafeArea: !PlatformUtils.isMobile,
    builder: (_) => _DriveCollaboratorPickerDialog(
      initialSelected: initialSelected,
      disabledIds: disabledIds,
    ),
  );
}

class DriveCollaboratorInputRow extends StatelessWidget {
  const DriveCollaboratorInputRow({
    super.key,
    required this.collaborators,
    required this.onPick,
    required this.onRemove,
  });

  final List<ContactPerson> collaborators;
  final VoidCallback onPick;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final height = UiFieldStyle.defaultHeight;
    final radius = UiFieldStyle.defaultBorderRadius;
    return Container(
      constraints: BoxConstraints(minHeight: height),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD9E2F2)),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: collaborators.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '添加成员',
                        style: TextStyle(color: const Color(0xFFA0AEC0)),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Row(
                      children: [
                        for (final p in collaborators)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _CollaboratorChip(
                              person: p,
                              onRemove: () => onRemove(p.id),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          SizedBox(
            width: 1,
            height: height - 12,
            child: const ColoredBox(color: Color(0xFFE5EAF3)),
          ),
          SizedBox(
            width: height,
            height: height,
            child: IconButton(
              tooltip: '添加协作者',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: const Icon(CupertinoIcons.add, size: 18),
              onPressed: onPick,
            ),
          ),
        ],
      ),
    );
  }
}

class DriveCollaboratorAvatar extends StatelessWidget {
  const DriveCollaboratorAvatar({
    super.key,
    required this.url,
    required this.name,
    this.size = 24,
  });

  final String url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final raw = url.trim();
    final lower = raw.toLowerCase();
    final hasAvatar = raw.isNotEmpty &&
        !lower.contains('.svg') &&
        !lower.contains('/svg') &&
        !lower.contains('/portrait/default/');
    if (hasAvatar) {
      return UiNetworkImage(
        imageUrl: raw,
        cacheKey: stableAvatarCacheKey(raw),
        width: size,
        height: size,
        fit: BoxFit.cover,
        borderRadius: size / 2,
        placeholderBuilder: (_, __) => _fallback(),
        errorBuilder: (_, __, ___) => _fallback(),
        imageBuilder: (context, provider) => ClipOval(
          child: Image(
            image: provider,
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final initial = name.trim().characters.take(1).toString();
    final colors = [
      const Color(0xFF2F80ED),
      const Color(0xFF7C3AED),
      const Color(0xFF10A37F),
      const Color(0xFFF59E0B),
      const Color(0xFFEF4444),
      const Color(0xFF0EA5E9),
    ];
    final seed = name.codeUnits.fold<int>(0, (sum, v) => sum + v);
    final color = colors[seed % colors.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      alignment: Alignment.center,
      child: Text(
        initial.isEmpty ? '?' : initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size <= 22 ? 11 : 12,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

class _DriveCollaboratorPickerDialog extends StatefulWidget {
  const _DriveCollaboratorPickerDialog({
    required this.initialSelected,
    required this.disabledIds,
  });
  final List<ContactPerson> initialSelected;
  final Set<String> disabledIds;

  @override
  State<_DriveCollaboratorPickerDialog> createState() =>
      _DriveCollaboratorPickerDialogState();
}

class _DriveCollaboratorPickerDialogState
    extends State<_DriveCollaboratorPickerDialog> {
  late Future<List<ContactDepartment>> _departments;
  late Future<List<ContactPerson>> _humans;
  late Future<List<ConversationItem>> _groups;
  late final Future<(List<ContactDepartment>, List<ContactPerson>)>
      _contactSources;
  late final Set<String> _selectedIds;
  late final Map<String, ContactPerson> _selectedById;
  final Set<String> _expandedDepartments = {};
  String _query = '';
  bool _showGroups = false;
  ConversationItem? _activeGroup;
  Future<List<ContactPerson>>? _activeGroupMembers;
  String _currentAccountUuid = '';
  String? _activePersonId;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.initialSelected.map((p) => p.id).toSet();
    _selectedById = {for (final p in widget.initialSelected) p.id: p};
    _departments =
        const ContactsService().tree().then(buildContactDepartmentTree);
    _humans = const ContactsService().members(kind: 'human', keyword: '');
    _groups = OpenClawChatService().listAllConversations(pageSize: 100).then(
          (items) => items
              .where((item) => item.isGroup && (item.roomUuid ?? '').isNotEmpty)
              .toList(growable: false),
        );
    _contactSources = Future.wait<dynamic>([_departments, _humans]).then(
      (values) => (
        values[0] as List<ContactDepartment>,
        values[1] as List<ContactPerson>,
      ),
    );
    // ignore: discarded_futures
    _loadCurrentAccount();
  }

  Future<void> _loadCurrentAccount() async {
    try {
      final me = await fetchMeApi();
      final account = me.account;
      final uuid = (account['uuid'] ??
              account['account_uuid'] ??
              account['accountUuid'] ??
              '')
          .toString();
      if (!mounted || uuid.isEmpty) return;
      setState(() {
        _currentAccountUuid = uuid;
        _selectedIds.remove(uuid);
        _selectedById.remove(uuid);
      });
    } catch (_) {
      // 取不到当前账号时只影响“自己禁选”兜底，不阻断协作者选择。
    }
  }

  void _search(String value) {
    setState(() {
      _query = value.trim();
      if (_query.isNotEmpty) _showGroups = false;
      _activeGroup = null;
      _activeGroupMembers = null;
      _humans = const ContactsService().members(kind: 'human', keyword: _query);
    });
  }

  void _toggle(ContactPerson p) {
    if (_isDisabled(p)) return;
    setState(() {
      _activePersonId = p.id;
      if (_selectedIds.contains(p.id)) {
        _selectedIds.remove(p.id);
        _selectedById.remove(p.id);
      } else {
        _selectedIds.add(p.id);
        _selectedById[p.id] = p;
      }
    });
  }

  void _selectVisible(List<ContactPerson> people) {
    setState(() {
      for (final p
          in people.where((p) => p.kind == 'human' && !_isDisabled(p))) {
        _selectedIds.add(p.id);
        _selectedById[p.id] = p;
      }
    });
  }

  bool _isSelf(ContactPerson p) =>
      _currentAccountUuid.isNotEmpty && p.id == _currentAccountUuid;

  bool _isDisabled(ContactPerson p) =>
      _isSelf(p) || widget.disabledIds.contains(p.id);

  List<ContactPerson> _peopleForDepartment(
    ContactDepartment department,
    List<ContactPerson> people,
  ) {
    final name = department.name.trim();
    if (name.isEmpty) return const <ContactPerson>[];
    return people
        .where((person) => person.departmentName.trim() == name)
        .toList(growable: false);
  }

  List<ContactPerson> _peopleInSubtree(
    ContactDepartment department,
    List<ContactPerson> people,
  ) {
    final result = <ContactPerson>[
      ..._peopleForDepartment(department, people)
    ];
    for (final child in department.children) {
      result.addAll(_peopleInSubtree(child, people));
    }
    final seen = <String>{};
    return result
        .where((person) => seen.add(person.id))
        .toList(growable: false);
  }

  bool _departmentChecked(
    ContactDepartment department,
    List<ContactPerson> people,
  ) {
    final members = _peopleInSubtree(department, people)
        .where((p) => !_isDisabled(p))
        .toList();
    return members.isNotEmpty &&
        members.every((p) => _selectedIds.contains(p.id));
  }

  void _toggleDepartment(
    ContactDepartment department,
    List<ContactPerson> people,
  ) {
    final members = _peopleInSubtree(department, people)
        .where((p) => !_isDisabled(p))
        .toList();
    if (members.isEmpty) return;
    final checked = members.every((p) => _selectedIds.contains(p.id));
    setState(() {
      if (checked) {
        for (final p in members) {
          _selectedIds.remove(p.id);
          _selectedById.remove(p.id);
        }
      } else {
        for (final p in members) {
          _selectedIds.add(p.id);
          _selectedById[p.id] = p;
        }
      }
    });
  }

  Future<List<ContactPerson>> _loadGroupMembers(ConversationItem group) async {
    final roomUuid = group.roomUuid;
    if (roomUuid == null || roomUuid.isEmpty) return const <ContactPerson>[];
    final detail = await RoomsService().getGroupRoom(roomUuid);
    return detail.members
        .where((m) => m.kind == 'human' && m.id.isNotEmpty)
        .map<ContactPerson>(
          (m) => ContactPerson(
            kind: 'human',
            id: m.id,
            displayName: m.displayName.isEmpty ? '未命名成员' : m.displayName,
            avatarUrl: m.avatar,
            subtitle: group.title,
            positionLabel: '',
            departmentId: '',
            departmentName: '',
            source: 'group',
            skills: const <AgentSkillItem>[],
            apps: const <AgentAppItem>[],
            lifecycleStatus: 'active',
            canChat: true,
          ),
        )
        .toList(growable: false);
  }

  void _openGroup(ConversationItem group) {
    setState(() {
      _activeGroup = group;
      _activeGroupMembers = _loadGroupMembers(group);
    });
  }

  void _removeSelected(String id) {
    setState(() {
      _selectedIds.remove(id);
      _selectedById.remove(id);
    });
  }

  List<Widget> _departmentRows(
    List<ContactDepartment> rows,
    List<ContactPerson> people, [
    int depth = 0,
  ]) {
    final out = <Widget>[];
    for (final dept in rows) {
      final hasChildren = dept.children.isNotEmpty;
      final expanded = _expandedDepartments.contains(dept.id);
      final deptPeople = _peopleForDepartment(dept, people);
      out.add(_DepartmentTreeRow(
        department: dept,
        depth: depth,
        expanded: expanded,
        checked: _departmentChecked(dept, people),
        onToggleExpand: () => setState(() {
          if (expanded) {
            _expandedDepartments.remove(dept.id);
          } else {
            _expandedDepartments.add(dept.id);
          }
        }),
        onToggleChecked: () => _toggleDepartment(dept, people),
      ));
      if (expanded) {
        for (final person in deptPeople) {
          final disabled = _isDisabled(person);
          out.add(_ContactPersonRow(
            person: person,
            selected: _selectedIds.contains(person.id),
            active: _activePersonId == person.id,
            disabled: disabled,
            depth: depth + 1,
            onTap: () => _toggle(person),
          ));
        }
        if (hasChildren) {
          out.addAll(_departmentRows(dept.children, people, depth + 1));
        }
      }
    }
    return out;
  }

  Widget _buildLeftPane() {
    return Container(
      width: 300,
      color: const Color(0xFFF7F8FA),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: UiSearchField(
              hintText: '搜索',
              onChanged: _search,
              borderRadius: 6,
              fillColor: Colors.white,
            ),
          ),
          Expanded(
            child: _query.isNotEmpty
                ? _buildPeopleList()
                : (_activeGroup != null
                    ? _buildActiveGroupMembers()
                    : _buildContactSources()),
          ),
        ],
      ),
    );
  }

  Widget _buildContactSources() {
    return FutureBuilder<(List<ContactDepartment>, List<ContactPerson>)>(
      future: _contactSources,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CupertinoActivityIndicator(radius: 12));
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '加载通讯录失败:${snap.error}',
                style: const TextStyle(color: Color(0xFFE5484D)),
              ),
            ),
          );
        }
        final departments = snap.data?.$1 ?? const <ContactDepartment>[];
        final people = snap.data?.$2 ?? const <ContactPerson>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            _ContactSourceRow(
              icon: CupertinoIcons.person_2_fill,
              label: '从群聊中选择',
              selected: _showGroups,
              onTap: () => setState(() {
                _showGroups = true;
                _activeGroup = null;
                _activeGroupMembers = null;
                _query = '';
              }),
            ),
            const SizedBox(height: 8),
            if (_showGroups) ...[
              _buildInlineGroupList(),
              const Padding(
                padding: EdgeInsets.fromLTRB(32, 8, 0, 8),
                child: Divider(height: 1, color: Color(0xFFE8EBF0)),
              ),
            ],
            if (departments.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '暂无组织架构',
                  style: TextStyle(color: Color(0xFF8C8C8C), fontSize: 13),
                ),
              )
            else
              ..._departmentRows(departments, people),
          ],
        );
      },
    );
  }

  Widget _buildPeopleList() {
    return FutureBuilder<List<ContactPerson>>(
      future: _humans,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CupertinoActivityIndicator(radius: 12));
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '加载通讯录失败:${snap.error}',
                style: const TextStyle(color: Color(0xFFE5484D)),
              ),
            ),
          );
        }
        final people = (snap.data ?? const <ContactPerson>[])
            .where((p) => p.kind == 'human')
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
              child: Row(
                children: [
                  if (_query.isNotEmpty)
                    IconButton(
                      tooltip: '返回',
                      splashRadius: 16,
                      icon: const Icon(CupertinoIcons.arrow_left, size: 17),
                      onPressed: () => setState(() {
                        _query = '';
                        _humans = const ContactsService()
                            .members(kind: 'human', keyword: '');
                      }),
                    ),
                  Expanded(
                    child: Text(
                      _query.isEmpty ? '联系人' : '搜索结果',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1F2329),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed:
                        people.isEmpty ? null : () => _selectVisible(people),
                    child: const Text('全选'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: people.isEmpty
                  ? const Center(
                      child: Text(
                        '没有可添加的协作者',
                        style:
                            TextStyle(color: Color(0xFF8C8C8C), fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: people.length,
                      itemBuilder: (_, i) {
                        final p = people[i];
                        final disabled = _isDisabled(p);
                        return _ContactPersonRow(
                          person: p,
                          selected: _selectedIds.contains(p.id),
                          active: _activePersonId == p.id,
                          disabled: disabled,
                          onTap: () => _toggle(p),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInlineGroupList() {
    return FutureBuilder<List<ConversationItem>>(
      future: _groups,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CupertinoActivityIndicator(radius: 12)),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '加载群聊失败:${snap.error}',
              style: const TextStyle(color: Color(0xFFE5484D)),
            ),
          );
        }
        final groups = snap.data ?? const <ConversationItem>[];
        if (groups.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '暂无可选择的群聊',
              style: TextStyle(color: Color(0xFF8C8C8C), fontSize: 13),
            ),
          );
        }
        return Column(
          children: [
            for (final group in groups)
              _GroupConversationRow(
                group: group,
                onTap: () => _openGroup(group),
              ),
          ],
        );
      },
    );
  }

  Widget _buildActiveGroupMembers() {
    final group = _activeGroup!;
    return FutureBuilder<List<ContactPerson>>(
      future: _activeGroupMembers,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CupertinoActivityIndicator(radius: 12));
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '加载群成员失败:${snap.error}',
                style: const TextStyle(color: Color(0xFFE5484D)),
              ),
            ),
          );
        }
        final people = snap.data ?? const <ContactPerson>[];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: SizedBox(
                height: 32,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      icon: const Icon(CupertinoIcons.arrow_left, size: 17),
                      onPressed: () => setState(() {
                        _activeGroup = null;
                        _activeGroupMembers = null;
                        _showGroups = true;
                      }),
                    ),
                    Expanded(
                      child: Text(
                        group.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F2329),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed:
                          people.isEmpty ? null : () => _selectVisible(people),
                      child: const Text('全选'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: people.isEmpty
                  ? const Center(
                      child: Text(
                        '该群聊暂无可添加成员',
                        style:
                            TextStyle(color: Color(0xFF8C8C8C), fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: people.length,
                      itemBuilder: (_, i) {
                        final p = people[i];
                        final disabled = _isDisabled(p);
                        return _ContactPersonRow(
                          person: p,
                          selected: _selectedIds.contains(p.id),
                          active: _activePersonId == p.id,
                          disabled: disabled,
                          onTap: () => _toggle(p),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRightPane() {
    final selected =
        _selectedById.values.where((p) => !_isDisabled(p)).toList();
    return Expanded(
      child: Container(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择联系人',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1F2329),
                      ),
                    ),
                  ),
                  Text(
                    selected.isEmpty ? '' : '已选择 ${selected.length} 个联系人',
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFF8C8C8C)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: selected.isEmpty
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      itemCount: selected.length,
                      itemBuilder: (_, i) {
                        final p = selected[i];
                        return _SelectedContactRow(
                          person: p,
                          onRemove: () => _removeSelected(p.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformUtils.isMobile) return _buildMobileLayout();
    return UiPickerDialog(
      size: UiDialogSize.standard,
      maxHeight: 590,
      child: SizedBox(
        height: 590,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
              child: UiSheetHeader(
                title: '添加协作者',
                subtitle: '从通讯录中选择可访问该文件夹的成员',
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  _buildLeftPane(),
                  const VerticalDivider(width: 1, color: Color(0xFFE5E7EB)),
                  _buildRightPane(),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFF0F0F0))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 132,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 132,
                    child: FilledButton(
                      onPressed: _selectedById.values
                              .where((p) => !_isDisabled(p))
                              .isEmpty
                          ? null
                          : () => Navigator.of(context).pop(_selectedById.values
                              .where((p) => !_isDisabled(p))
                              .toList()),
                      child: const Text('确定'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    final selected = _selectedById.values.where((p) => !_isSelf(p)).toList();
    return UiPickerDialog.fullScreen(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
              child: UiSheetHeader(
                title: '添加协作者',
                subtitle: '从通讯录中选择可访问该文件夹的成员',
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: UiSearchField(
                hintText: '搜索',
                onChanged: _search,
                borderRadius: 8,
                fillColor: const Color(0xFFF7F8FA),
              ),
            ),
            if (selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: selected.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => _CollaboratorChip(
                      person: selected[i],
                      onRemove: () => _toggle(selected[i]),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _query.isNotEmpty
                  ? _buildPeopleList()
                  : (_activeGroup != null
                      ? _buildActiveGroupMembers()
                      : _buildContactSources()),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFF0F0F0))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(selected),
                      child: const Text('确定'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupConversationRow extends StatelessWidget {
  const _GroupConversationRow({
    required this.group,
    required this.onTap
  });

  final ConversationItem group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: SizedBox(
        height: 38,
        child: Row(
          children: [
            const SizedBox(width: 32),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF2FF),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Icon(
                CupertinoIcons.person_2_fill,
                size: 14,
                color: Color(0xFF4E8DFF),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                group.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF1F2329)
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DepartmentTreeRow extends StatelessWidget {
  const _DepartmentTreeRow({
    required this.department,
    required this.depth,
    required this.expanded,
    required this.checked,
    required this.onToggleExpand,
    required this.onToggleChecked,
  });

  final ContactDepartment department;
  final int depth;
  final bool expanded;
  final bool checked;
  final VoidCallback onToggleExpand;
  final VoidCallback onToggleChecked;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onToggleExpand,
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              _PickerCheckBox(checked: checked, onTap: onToggleChecked),
              const SizedBox(width: 8),
              Icon(
                expanded
                    ? CupertinoIcons.chevron_down
                    : CupertinoIcons.chevron_right,
                size: 11,
                color: const Color(0xFF9AA3AF),
              ),
              const SizedBox(width: 5),
              const Icon(
                CupertinoIcons.folder_fill,
                size: 18,
                color: Color(0xFF4E8DFF),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  department.name.isEmpty ? '未命名部门' : department.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF1F2329),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactSourceRow extends StatelessWidget {
  const _ContactSourceRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          height: 32,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE9F2FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              const SizedBox(width: 32),
              Icon(icon, size: 17, color: const Color(0xFF4E8DFF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF1F2329)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactPersonRow extends StatelessWidget {
  const _ContactPersonRow({
    required this.person,
    required this.selected,
    required this.onTap,
    this.active = false,
    this.disabled = false,
    this.depth = 0,
  });

  final ContactPerson person;
  final bool selected;
  final VoidCallback onTap;
  final bool active;
  final bool disabled;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final checked = disabled ? true : selected;
    final highlighted = active && !disabled;
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: disabled ? null : onTap,
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: highlighted ? const Color(0xFF2F7DFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              _PickerCheckBox(
                checked: checked,
                onTap: onTap,
                enabled: !disabled,
                checkedBackground:
                    highlighted ? Colors.white : const Color(0xFF2F7DFF),
                checkedIconColor:
                    highlighted ? const Color(0xFF2F7DFF) : Colors.white,
                disabledBackground: const Color(0xFFE5E7EB),
                disabledIconColor: Colors.white,
              ),
              const SizedBox(width: 8),
              DriveCollaboratorAvatar(
                url: person.avatarUrl,
                name: person.displayName,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  person.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: disabled
                        ? const Color(0xFF9AA3AF)
                        : (highlighted
                            ? Colors.white
                            : const Color(0xFF1F2329)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerCheckBox extends StatelessWidget {
  const _PickerCheckBox({
    required this.checked,
    required this.onTap,
    this.enabled = true,
    this.checkedBackground = const Color(0xFF2F7DFF),
    this.checkedIconColor = Colors.white,
    this.disabledBackground = const Color(0xFFE5E7EB),
    this.disabledIconColor = const Color(0xFF9AA3AF),
  });

  final bool checked;
  final VoidCallback onTap;
  final bool enabled;
  final Color checkedBackground;
  final Color checkedIconColor;
  final Color disabledBackground;
  final Color disabledIconColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 20,
        height: 20,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: checked
                  ? (enabled ? checkedBackground : disabledBackground)
                  : Colors.white,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: enabled
                    ? (checked
                        ? const Color(0xFF2F7DFF)
                        : const Color(0xFFA8B0BE))
                    : const Color(0xFFD1D5DB),
                width: 1.2,
              ),
            ),
            child: checked
                ? Icon(
                    CupertinoIcons.check_mark,
                    size: 11,
                    color: enabled ? checkedIconColor : disabledIconColor,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _SelectedContactRow extends StatelessWidget {
  const _SelectedContactRow({
    required this.person,
    required this.onRemove
  });

  final ContactPerson person;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          DriveCollaboratorAvatar(
            url: person.avatarUrl,
            name: person.displayName,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              person.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF1F2329)),
            ),
          ),
          IconButton(
            tooltip: '移除',
            splashRadius: 16,
            icon: const Icon(
              CupertinoIcons.xmark,
              size: 15,
              color: Color(0xFF9AA3AF),
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _CollaboratorChip extends StatelessWidget {
  const _CollaboratorChip({
    required this.person,
    required this.onRemove
  });

  final ContactPerson person;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      constraints: const BoxConstraints(maxWidth: 150),
      padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        border: Border.all(color: const Color(0xFFDDE5F0)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DriveCollaboratorAvatar(
            url: person.avatarUrl,
            name: person.displayName,
            size: 22,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              person.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1F2329),
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onRemove,
            child: const SizedBox(
              width: 18,
              height: 18,
              child: Icon(
                CupertinoIcons.xmark,
                size: 12,
                color: Color(0xFF8C96A5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
