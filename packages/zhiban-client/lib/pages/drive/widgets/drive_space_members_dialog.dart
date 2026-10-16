import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_collaborator_picker.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

/// 共享文件夹「权限管理」弹窗(F06 基础设置 slice,首版只做协作者管理)。
///
/// - 列表:list 后端 MemberResp,角色用本地 dropdown 直接 update。
/// - 添加:复用共享文件夹创建时的通讯录选择器,批量 addMember。
/// - 移除:列表项的删除按钮 → removeMember。
/// - 权限完全以后端 manager+ 鉴权为准;非授权 caller 会被后端 403,客户端只 toast。
///
/// 故意不做:安全设置 tab、邀请链接、部门/全公司 subject、可下载子权限。
Future<void> showDriveSpaceMembersDialog(
  BuildContext context,
  WidgetRef ref,
  DriveSpace space,
) async {
  await _showDriveMembersDialog(
    context,
    DrivePermissionTarget.space(space)
  );
}

Future<void> showDriveFolderMembersDialog(
  BuildContext context,
  WidgetRef ref,
  DriveSpace ownerSpace,
  DriveFolder folder,
) async {
  await _showDriveMembersDialog(
    context,
    DrivePermissionTarget.folder(ownerSpace: ownerSpace, folder: folder),
  );
}

Future<void> _showDriveMembersDialog(
  BuildContext context,
  DrivePermissionTarget target,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => UncontrolledProviderScope(
      container: container,
      child: _SpaceMembersDialog(target: target),
    ),
  );
}

class DrivePermissionTarget {
  const DrivePermissionTarget._({
    required this.kind,
    required this.uuid,
    required this.title,
    required this.ownerSpaceUuid,
  });

  final String kind; // space | folder
  final String uuid;
  final String title;
  final String ownerSpaceUuid;

  bool get isFolder => kind == 'folder';
  String get providerKey => isFolder ? 'folder:$uuid' : uuid;

  factory DrivePermissionTarget.space(DriveSpace space) =>
      DrivePermissionTarget._(
        kind: 'space',
        uuid: space.uuid,
        title: space.displayName,
        ownerSpaceUuid: space.uuid,
      );

  factory DrivePermissionTarget.folder({
    required DriveSpace ownerSpace,
    required DriveFolder folder,
  }) =>
      DrivePermissionTarget._(
        kind: 'folder',
        uuid: folder.uuid,
        title: folder.name,
        ownerSpaceUuid: ownerSpace.uuid,
      );
}

const List<({String value, String label})> _roles = [
  (value: 'manager', label: '可管理'),
  (value: 'editor', label: '可编辑'),
  (value: 'viewer', label: '可阅读'),
];

const double _memberRowHeight = 58;
const int _maxVisibleMemberRows = 10;

Set<String> driveExistingMemberIds(Iterable<SpaceMember> members) => {
      for (final member in members)
        if (member.accountUuid.isNotEmpty) member.accountUuid,
    };

bool canManageDriveMembers({
  required String currentAccountUuid,
  required Iterable<SpaceMember> members,
}) {
  if (currentAccountUuid.isEmpty) return false;
  return members.any((member) =>
      member.accountUuid == currentAccountUuid &&
      (member.role == 'owner' || member.role == 'manager'));
}

String _roleLabel(String role) {
  if (role == 'owner') return '可管理';
  for (final r in _roles) {
    if (r.value == role) return r.label;
  }
  return role;
}

String _roleDescription(String role) {
  switch (role) {
    case 'manager':
      return '可以编辑、分享内容和修改权限设置';
    case 'editor':
      return '可以上传、编辑和管理内容';
    case 'viewer':
      return '可以查看内容';
    default:
      return '';
  }
}

class _SpaceMembersDialog extends ConsumerStatefulWidget {
  const _SpaceMembersDialog({required this.target});
  final DrivePermissionTarget target;

  @override
  ConsumerState<_SpaceMembersDialog> createState() =>
      _SpaceMembersDialogState();
}

class _SpaceMembersDialogState extends ConsumerState<_SpaceMembersDialog> {
  bool _contactsLoading = true;
  Map<String, ContactPerson> _contactsByUuid = const {};
  String _currentAccountUuid = '';

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _loadCurrentAccountUuid();
  }

  Future<void> _loadContacts() async {
    try {
      final humans = await const ContactsService().members(kind: 'human');
      if (!mounted) return;
      setState(() {
        _contactsByUuid = {
          for (final human in humans)
            if (human.id.isNotEmpty) human.id: human,
        };
        _contactsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _contactsLoading = false);
    }
  }

  Future<void> _loadCurrentAccountUuid() async {
    try {
      final me = await fetchMeApi();
      final account = me.account;
      final uuid = (account['uuid'] ??
              account['account_uuid'] ??
              account['accountUuid'] ??
              '')
          .toString();
      if (uuid.isEmpty || !mounted) return;
      setState(() => _currentAccountUuid = uuid);
    } catch (_) {
      // 失败时前端管理入口保持关闭;后端 manager+ 鉴权仍是最终边界。
    }
  }

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      maxHeight: 760,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            _buildMembersPane(),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 12),
      child: UiSheetHeader(
        title: '${widget.target.title} · 权限管理',
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  Widget _buildFooter() {
    final members =
        ref.watch(driveSpaceMembersProvider(widget.target.providerKey)).value ??
            const <SpaceMember>[];
    if (!canManageDriveMembers(
      currentAccountUuid: _currentAccountUuid,
      members: members,
    )) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: _pickCollaborators,
            icon: const Icon(CupertinoIcons.add, size: 16),
            label: const Text('添加协作者'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCollaborators() async {
    final asyncMembers =
        ref.read(driveSpaceMembersProvider(widget.target.providerKey));
    final members = asyncMembers.value ?? const <SpaceMember>[];
    if (!canManageDriveMembers(
      currentAccountUuid: _currentAccountUuid,
      members: members,
    )) {
      BotToast.showText(text: '你没有管理协作者的权限');
      return;
    }
    final existingIds = driveExistingMemberIds(members);
    final picked = await showDriveCollaboratorPicker(
      context,
      initialSelected: const <ContactPerson>[],
      disabledIds: existingIds,
    );
    if (picked == null) return;
    final toAdd = picked.where((p) => !existingIds.contains(p.id)).toList();
    if (toAdd.isEmpty) {
      BotToast.showText(text: '没有新增协作者');
      return;
    }
    final svc = ref.read(driveServiceProvider);
    final cancel = BotToast.showLoading();
    int success = 0;
    int failed = 0;
    try {
      for (final p in toAdd) {
        try {
          if (widget.target.isFolder) {
            await svc.addFolderMember(
              folderUuid: widget.target.uuid,
              accountUuid: p.id,
              role: 'editor',
            );
          } else {
            await svc.addSpaceMember(
              spaceUuid: widget.target.uuid,
              accountUuid: p.id,
              role: 'editor',
            );
          }
          success += 1;
        } catch (_) {
          failed += 1;
        }
      }
      await ref
          .read(driveSpaceMembersProvider(widget.target.providerKey).notifier)
          .reload();
      if (success > 0) {
        setState(() {
          _contactsByUuid = {
            ..._contactsByUuid,
            for (final p in toAdd) p.id: p,
          };
        });
      }
      BotToast.showText(
        text: failed == 0
            ? '已添加 $success 个协作者'
            : '已添加 $success 个协作者,$failed 个添加失败',
      );
    } finally {
      cancel();
    }
  }

  Widget _buildMembersPane() {
    final async =
        ref.watch(driveSpaceMembersProvider(widget.target.providerKey));
    final svc = ref.read(driveServiceProvider);
    return async.when(
      loading: () => const SizedBox(
        height: 160,
        child: Center(child: CupertinoActivityIndicator(radius: 12)),
      ),
      error: (e, _) => SizedBox(
        height: 180,
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('加载协作者失败:$e',
                style: const TextStyle(color: Color(0xFFE5484D))),
          ),
        ),
      ),
      data: (members) {
        final canManage = canManageDriveMembers(
          currentAccountUuid: _currentAccountUuid,
          members: members,
        );
        final displayMembers = <SpaceMember>[
          ...members.where((m) => m.role == 'owner'),
          ...members.where((m) => m.role != 'owner'),
        ];
        if (displayMembers.isEmpty) {
          return const SizedBox(
            height: 160,
            child: Center(
              child: Text('暂无协作者', style: TextStyle(color: Color(0xFF8C8C8C))),
            ),
          );
        }
        final visibleRows = displayMembers.length > _maxVisibleMemberRows
            ? _maxVisibleMemberRows
            : displayMembers.length;
        final listHeight = visibleRows * _memberRowHeight +
            (visibleRows > 0 ? visibleRows - 1 : 0);
        return SizedBox(
          height: listHeight,
          child: Scrollbar(
            thumbVisibility: displayMembers.length > _maxVisibleMemberRows,
            child: ListView.separated(
              padding: EdgeInsets.zero,
              physics: displayMembers.length > _maxVisibleMemberRows
                  ? null
                  : const NeverScrollableScrollPhysics(),
              itemCount: displayMembers.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: Color(0xFFF5F5F5)),
              itemBuilder: (_, i) {
                final m = displayMembers[i];
                final isOwner = m.role == 'owner';
                return _MemberRow(
                    member: m,
                    contact: _contactsByUuid[m.accountUuid],
                    contactsLoading: _contactsLoading,
                    roleLocked: isOwner || !canManage,
                    onChangeRole: (newRole) async {
                      if (isOwner || !canManage) return;
                      if (newRole == m.role) return;
                      final provider =
                          driveSpaceMembersProvider(widget.target.providerKey);
                      final previous = ref.read(provider).value;
                      ref
                          .read(provider.notifier)
                          .updateRoleLocal(m.accountUuid, newRole);
                      try {
                        if (widget.target.isFolder) {
                          await svc.updateFolderMember(
                            folderUuid: widget.target.uuid,
                            accountUuid: m.accountUuid,
                            role: newRole,
                          );
                        } else {
                          await svc.updateSpaceMember(
                            spaceUuid: widget.target.uuid,
                            accountUuid: m.accountUuid,
                            role: newRole,
                          );
                        }
                        BotToast.showText(text: '已更新角色');
                      } catch (e) {
                        if (previous != null) {
                          ref.read(provider.notifier).replaceLocal(previous);
                        } else {
                          await ref.read(provider.notifier).reload();
                        }
                        BotToast.showText(text: '更新失败:$e');
                      }
                    },
                    onRemove: () async {
                      if (isOwner || !canManage) return;
                      final ok = await showUiConfirmDialog(
                        context,
                        title: '移除协作者',
                        description: '确定从该共享文件夹移除该协作者?',
                        confirmLabel: '移除',
                        danger: true,
                      );
                      if (!ok) return;
                      final provider =
                          driveSpaceMembersProvider(widget.target.providerKey);
                      final previous = ref.read(provider).value;
                      ref.read(provider.notifier).removeLocal(m.accountUuid);
                      try {
                        if (widget.target.isFolder) {
                          await svc.removeFolderMember(
                            folderUuid: widget.target.uuid,
                            accountUuid: m.accountUuid,
                          );
                        } else {
                          await svc.removeSpaceMember(
                            spaceUuid: widget.target.uuid,
                            accountUuid: m.accountUuid,
                          );
                        }
                        await ref.read(provider.notifier).reload();
                        BotToast.showText(text: '已移除');
                      } catch (e) {
                        if (previous != null) {
                          ref.read(provider.notifier).replaceLocal(previous);
                        } else {
                          await ref.read(provider.notifier).reload();
                        }
                        BotToast.showText(text: '移除失败:$e');
                      }
                    });
              },
            ),
          ),
        );
      },
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.contact,
    required this.contactsLoading,
    required this.roleLocked,
    required this.onChangeRole,
    required this.onRemove,
  });

  final SpaceMember member;
  final ContactPerson? contact;
  final bool contactsLoading;
  final bool roleLocked;
  final ValueChanged<String> onChangeRole;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = contact;
    final name = (p?.displayName ?? '').trim().isNotEmpty
        ? p!.displayName.trim()
        : (contactsLoading ? '加载协作者信息…' : '未知协作者');
    final department = (p?.departmentName ?? '').trim().isNotEmpty
        ? p!.departmentName.trim()
        : (contactsLoading ? '正在解析成员信息' : '暂无部门信息');
    return SizedBox(
      height: _memberRowHeight,
      child: Row(
        children: [
          const SizedBox(width: 28),
          DriveCollaboratorAvatar(
            url: p?.avatarUrl ?? '',
            name: name,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF1F2329),
                        ),
                      ),
                    ),
                    if (member.role == 'owner') ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF2FF),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '所有者',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF1D5FD7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    department,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF8C8C8C)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _RoleActionButton(
            value: member.role,
            enabled: !roleLocked,
            onChanged: onChangeRole,
            onRemove: roleLocked ? null : onRemove,
          ),
          const SizedBox(width: 28),
        ],
      ),
    );
  }
}

class _RoleActionButton extends StatelessWidget {
  const _RoleActionButton({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.onRemove,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: enabled
          ? () async {
              final box = context.findRenderObject() as RenderBox;
              final overlay = Navigator.of(context)
                  .overlay!
                  .context
                  .findRenderObject() as RenderBox;
              final offset = box.localToGlobal(Offset.zero, ancestor: overlay);
              final selected = await showMenu<String>(
                context: context,
                color: Colors.white,
                elevation: 12,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
                position: RelativeRect.fromRect(
                  Rect.fromLTWH(offset.dx, offset.dy + box.size.height,
                      box.size.width, box.size.height),
                  Offset.zero & overlay.size,
                ),
                items: [
                  for (final r in _roles)
                    PopupMenuItem<String>(
                      value: r.value,
                      padding: EdgeInsets.zero,
                      child: _RoleMenuItem(
                        label: r.label,
                        description: _roleDescription(r.value),
                        selected: r.value == value,
                      ),
                    ),
                  if (onRemove != null)
                    const PopupMenuItem<String>(
                      value: '_remove',
                      padding: EdgeInsets.zero,
                      child: _PlainMenuItem(label: '移除', danger: true),
                    ),
                ],
              );
              if (selected == null) return;
              if (selected == '_remove') {
                onRemove?.call();
                return;
              }
              onChanged(selected);
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _roleLabel(value),
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF1F2329),
                fontWeight: FontWeight.w500,
              ),
            ),
            if (enabled) ...[
              const SizedBox(width: 6),
              const Icon(
                CupertinoIcons.chevron_down,
                size: 15,
                color: Color(0xFF4E5969),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RoleMenuItem extends StatelessWidget {
  const _RoleMenuItem({
    required this.label,
    required this.description,
    required this.selected,
  });

  final String label;
  final String description;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: selected
                          ? const Color(0xFF1D5FD7)
                          : const Color(0xFF1F2329),
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (description.isNotEmpty && label == '可管理')
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        description,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                          height: 1.25,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                CupertinoIcons.check_mark,
                size: 16,
                color: Color(0xFF1D5FD7),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlainMenuItem extends StatelessWidget {
  const _PlainMenuItem({
    required this.label,
    this.danger = false
  });

  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            color: danger ? const Color(0xFFE5484D) : const Color(0xFF1F2329),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
