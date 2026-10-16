import 'package:zhiban_client/pages/drive/drive_page.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_navigation.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_space_members_dialog.dart';
import 'package:zhiban_client/pages/drive/widgets/folder_picker.dart';
import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:zhiban_client/pages/knowledge/providers/knowledge_providers.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_dropdown_menu.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 云盘页中间侧栏:云盘标题 + 快捷入口 + 空间。
class DriveSidebar extends ConsumerStatefulWidget {
  const DriveSidebar({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  ConsumerState<DriveSidebar> createState() => _DriveSidebarState();
}

class _DriveSidebarState extends ConsumerState<DriveSidebar> {
  // 默认展开：个人/共享根 + 云盘/知识库分类。共享侧只暴露“协作文件夹”，
  // 不暴露后端 shared space 概念。
  final Set<String> _expanded = <String>{};
  bool _seeded = false;

  void _toggle(String key) => setState(() =>
      _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key));

  String _rootKey(String spaceUuid) => 'sp-$spaceUuid-root';
  String _driveKey(String spaceUuid) => 'sp-$spaceUuid-drive';
  String _kbKey(String spaceUuid) => 'sp-$spaceUuid-kb';

  // 共享是虚拟顶层桶(无单一 space uuid),用静态 key。
  static const String _kSharedRootKey = 'shared-root';
  static const String _kSharedDriveKey = 'shared-drive';
  static const String _kSharedKbKey = 'shared-kb';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(driveTreeProvider).value;
    final selectedFolder = ref.watch(selectedFolderProvider);
    final selection = ref.watch(driveSelectionProvider);

    if (state == null) {
      return const SizedBox.shrink();
    }

    // 首次拿到 tree 后,默认展开个人/共享根与云盘分类。
    final personal = state.personal;
    final orgSpaces = state.orgSpaces;
    if (!_seeded && personal != null) {
      _seeded = true;
      _expanded
        ..add(_rootKey(personal.uuid))
        ..add(_driveKey(personal.uuid))
        ..add(_kbKey(personal.uuid))
        ..add(_kSharedRootKey)
        ..add(_kSharedDriveKey);
    }

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
      ),
      child: Column(
        children: [
          if (widget.showTitle) const _SidebarTitle(text: '云盘'),
          if (PlatformUtils.isDesktop) const SizedBox(height: 10),
          _SidebarLeafItem(
            icon: CupertinoIcons.clock,
            label: '最近使用',
            selected: selection.kind == DriveSelectionKind.recent,
            onTap: () {
              openDriveSelection(
                context,
                ref,
                selection:
                    const DriveSelection(kind: DriveSelectionKind.recent),
                space: ref.read(selectedSpaceProvider),
              );
            },
          ),
          _SidebarLeafItem(
            icon: CupertinoIcons.star,
            label: '我的收藏',
            selected: selection.kind == DriveSelectionKind.favorite,
            onTap: () {
              openDriveSelection(
                context,
                ref,
                selection:
                    const DriveSelection(kind: DriveSelectionKind.favorite),
                space: ref.read(selectedSpaceProvider),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Divider(height: 1, color: Color(0xFFEFF1F5)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 0, bottom: 4),
              children: [
                if (personal != null)
                  _SpaceTreeRoot(
                    spaceUuid: personal.uuid,
                    label: '我的空间',
                    icon: CupertinoIcons.home,
                    showKb: true,
                    kbScope: 'personal',
                    isExpanded: _expanded.contains(_rootKey(personal.uuid)),
                    onToggle: () => _toggle(_rootKey(personal.uuid)),
                    driveKey: _driveKey(personal.uuid),
                    kbKey: _kbKey(personal.uuid),
                    selectedUuid: selectedFolder,
                    expanded: _expanded,
                    onToggleFolder: _toggle,
                  ),
                // F06 IA cutover:用户可见根收口为「我的空间 / 共享空间」,二级保留
                // 「云盘 / 知识库」分类。共享云盘下第一层仍映射 shared space,
                // 但 UI 按“协作文件夹”呈现,不暴露“空间”概念。
                // 详 docs/plans/drive-two-bucket-rethink.md。
                _SharedSpaceRoot(
                  orgSpaces: orgSpaces,
                  isExpanded: _expanded.contains(_kSharedRootKey),
                  onToggle: () => _toggle(_kSharedRootKey),
                  driveKey: _kSharedDriveKey,
                  kbKey: _kSharedKbKey,
                  selectedUuid: selectedFolder,
                  expanded: _expanded,
                  onToggleFolder: _toggle,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(height: 1, color: Color(0xFFF0F0F0)),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: _SidebarLeafItem(
                icon: CupertinoIcons.delete_simple,
                label: '回收站',
                iconSize: 15,
                fontSize: 14,
                verticalPadding: 5,
                selected: selection.kind == DriveSelectionKind.recycle,
                onTap: () {
                  openDriveSelection(
                    context,
                    ref,
                    selection:
                        const DriveSelection(kind: DriveSelectionKind.recycle),
                    space: ref.read(selectedSpaceProvider),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部标题。
class _SidebarTitle extends StatelessWidget {
  const _SidebarTitle({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // 与对话区 header 保持同一层级的底部分隔线，增强左右区域分区感。
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEFF1F5))),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1F2329),
        ),
      ),
    );
  }
}

/// 普通叶子项("最近使用 / 我的收藏")。
/// 传 [onTap] 时变成可交互的入口。
class _SidebarLeafItem extends StatefulWidget {
  const _SidebarLeafItem({
    required this.icon,
    required this.label,
    this.selected = false,
    this.onTap,
    this.iconSize = 18,
    this.fontSize = 16,
    this.verticalPadding = 7,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final double iconSize;
  final double fontSize;
  final double verticalPadding;

  @override
  State<_SidebarLeafItem> createState() => _SidebarLeafItemState();
}

class _SidebarLeafItemState extends State<_SidebarLeafItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const selectedBg = Color(0xFFE6F0FF);
    const hoverBg = Color(0xFFF0F2F5);
    const selectedFg = Color(0xFF165DFF);

    Color bg = Colors.transparent;
    if (widget.selected) {
      bg = selectedBg;
    } else if (_hovered && widget.onTap != null) {
      bg = hoverBg;
    }

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: 12, vertical: widget.verticalPadding),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(widget.icon,
                size: widget.iconSize,
                color: widget.selected ? selectedFg : const Color(0xFF595959)),
            const SizedBox(width: 8),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: widget.fontSize,
                color: widget.selected ? selectedFg : const Color(0xFF1F2329),
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
    if (widget.onTap == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

/// 个人根。spaceUuid 为真实 personal space UUID。
class _SpaceTreeRoot extends ConsumerWidget {
  const _SpaceTreeRoot({
    required this.spaceUuid,
    required this.label,
    required this.icon,
    required this.showKb,
    required this.kbScope,
    required this.isExpanded,
    required this.onToggle,
    required this.driveKey,
    required this.kbKey,
    required this.selectedUuid,
    required this.expanded,
    required this.onToggleFolder,
  });

  final String spaceUuid;
  final String label;
  final IconData icon;
  final bool showKb;
  final String kbScope;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String driveKey;
  final String kbKey;
  final String selectedUuid;
  final Set<String> expanded;
  final void Function(String) onToggleFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(driveTreeProvider.notifier);
    final rootFolders = notifier.rootFoldersOf(spaceUuid);
    final selection = ref.watch(driveSelectionProvider);
    final selectedSpace = ref.watch(selectedSpaceProvider);
    final driveRootSelected = selection.kind == DriveSelectionKind.driveRoot &&
        selectedSpace == spaceUuid;
    final kbRootSelected =
        selection.kind == DriveSelectionKind.kbRoot && selectedSpace == kbScope;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 个人根行:只负责展开/折叠,业务入口在「云盘 / 知识库」二级分类。
        _FolderRow(
          icon: icon,
          label: label,
          depth: 0,
          isExpanded: isExpanded,
          hasChildren: true,
          isSelected: false,
          onToggle: onToggle,
          onTap: () {
            onToggle();
          },
        ),
        if (isExpanded) ...[
          _FolderRow(
            icon: CupertinoIcons.folder_fill,
            iconColor: const Color(0xFF165DFF),
            label: '云盘',
            depth: 1,
            isExpanded: expanded.contains(driveKey),
            hasChildren: rootFolders.isNotEmpty,
            isSelected: driveRootSelected,
            onToggle:
                rootFolders.isNotEmpty ? () => onToggleFolder(driveKey) : null,
            onTap: () {
              openDriveSelection(
                context,
                ref,
                selection:
                    const DriveSelection(kind: DriveSelectionKind.driveRoot),
                space: spaceUuid,
              );
              if (rootFolders.isNotEmpty) onToggleFolder(driveKey);
            },
          ),
          if (expanded.contains(driveKey))
            ...rootFolders.map((folder) => _FolderTreeItem(
                  folder: folder,
                  space: spaceUuid,
                  depth: 2,
                  selectedUuid: selectedUuid,
                  expanded: expanded,
                  onToggleFolder: onToggleFolder,
                )),

          // === 知识库 (KB list) ===
          if (showKb)
            _KbSubtree(
              kbScope: kbScope,
              ownerSpaceUuid: spaceUuid,
              depth: 1,
              isExpanded: expanded.contains(kbKey),
              isRootSelected: kbRootSelected,
              onToggle: () => onToggleFolder(kbKey),
              expanded: expanded,
              onToggleNode: onToggleFolder,
            ),
        ],
      ],
    );
  }
}

/// 共享(虚拟顶层桶)。F06 IA cutover:二级保留「云盘 / 知识库」分类,
/// 云盘下把 tenant + departments + shared 聚合为“协作文件夹列表”。
///
/// 长期:`drive_spaces.kind` 缩减为 `personal|shared`,部门退为 ACL subject。
/// 详 docs/plans/drive-two-bucket-rethink.md。
class _SharedSpaceRoot extends ConsumerWidget {
  const _SharedSpaceRoot({
    required this.orgSpaces,
    required this.isExpanded,
    required this.onToggle,
    required this.driveKey,
    required this.kbKey,
    required this.selectedUuid,
    required this.expanded,
    required this.onToggleFolder,
  });

  final List<DriveSpace> orgSpaces;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String driveKey;
  final String kbKey;
  final String selectedUuid;
  final Set<String> expanded;
  final void Function(String) onToggleFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driveExpanded = expanded.contains(driveKey);
    final kbExpanded = expanded.contains(kbKey);
    final hasSpaces = orgSpaces.isNotEmpty;
    final selection = ref.watch(driveSelectionProvider);
    final selectedSpace = ref.watch(selectedSpaceProvider);
    final driveRootSelected = selection.kind == DriveSelectionKind.driveRoot &&
        selectedSpace == 'org';
    final kbRootSelected =
        selection.kind == DriveSelectionKind.kbRoot && selectedSpace == 'org';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // === depth 0: 共享 根行 ===
        _FolderRow(
          icon: CupertinoIcons.building_2_fill,
          label: '共享空间',
          depth: 0,
          isExpanded: isExpanded,
          hasChildren: true,
          isSelected: false,
          onToggle: onToggle,
          onTap: () {
            onToggle();
          },
        ),
        if (isExpanded) ...[
          _FolderRow(
            icon: CupertinoIcons.folder_fill,
            iconColor: const Color(0xFF165DFF),
            label: '云盘',
            depth: 1,
            isExpanded: driveExpanded,
            hasChildren: true,
            isSelected: driveRootSelected,
            onToggle: hasSpaces ? () => onToggleFolder(driveKey) : null,
            onTap: () {
              openDriveSelection(
                context,
                ref,
                selection:
                    const DriveSelection(kind: DriveSelectionKind.driveRoot),
                space: 'org',
              );
              if (hasSpaces) onToggleFolder(driveKey);
            },
          ),
          if (driveExpanded)
            ...orgSpaces.map((sp) => _OrgSpaceNode(
                  space: sp,
                  depth: 2,
                  selectedUuid: selectedUuid,
                  expanded: expanded,
                  onToggleFolder: onToggleFolder,
                )),
          // === depth 1: 知识库 (scope='org') ===
          //
          // F06 cutover:共享知识库暂映射到 tenant KB;完整 shared space 绑定留后续。
          // 见 docs/plans/drive-two-bucket-rethink.md。
          _KbSubtree(
            kbScope: 'org',
            ownerSpaceUuid: '', // 共享根无单一 owner;KB 选中时不回填 selectedSpace
            depth: 1,
            isExpanded: kbExpanded,
            isRootSelected: kbRootSelected,
            onToggle: () => onToggleFolder(kbKey),
            expanded: expanded,
            onToggleNode: onToggleFolder,
          ),
        ],
      ],
    );
  }
}

/// 共享文件夹下,某具体 shared space 的用户可见命名节点。
/// 这一层按“协作文件夹”渲染,展开后显示该 space 的根 folders。
class _OrgSpaceNode extends ConsumerWidget {
  const _OrgSpaceNode({
    required this.space,
    required this.depth,
    required this.selectedUuid,
    required this.expanded,
    required this.onToggleFolder,
  });

  final DriveSpace space;
  final int depth;
  final String selectedUuid;
  final Set<String> expanded;
  final void Function(String) onToggleFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(driveTreeProvider.notifier);
    final rootFolders = notifier.rootFoldersOf(space.uuid);
    final key = 'sp-${space.uuid}-orgnode';
    final isExpanded = expanded.contains(key);
    final selection = ref.watch(driveSelectionProvider);
    final selectedSpace = ref.watch(selectedSpaceProvider);
    final isSelected = selection.kind == DriveSelectionKind.driveRoot &&
        selectedSpace == space.uuid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FolderRow(
          icon: Icons.folder_shared_outlined,
          leadingIcon: _SharedFolderIcon(selected: isSelected),
          iconColor:
              isSelected ? const Color(0xFF165DFF) : const Color(0xFF8C8C8C),
          label: space.displayName,
          depth: depth,
          isExpanded: isExpanded,
          hasChildren: rootFolders.isNotEmpty,
          isSelected: isSelected,
          onToggle: rootFolders.isNotEmpty ? () => onToggleFolder(key) : null,
          onTap: () {
            openDriveSelection(
              context,
              ref,
              selection:
                  const DriveSelection(kind: DriveSelectionKind.driveRoot),
              space: space.uuid,
            );
            if (rootFolders.isNotEmpty) onToggleFolder(key);
          },
          // F06 基础设置 slice:仅 `kind='shared'` 的 space 显示「权限管理」入口;
          // legacy tenant/department 不显示(权限由后端 manager+ 鉴权;前端先盖)。
          onSecondaryTapDown: space.kind == 'shared'
              ? (d) => _showSharedSpaceContextMenu(
                  context, ref, space, d.globalPosition)
              : null,
        ),
        if (isExpanded)
          ...rootFolders.map((folder) => _FolderTreeItem(
                folder: folder,
                space: space.uuid,
                ownerSpace: space.kind == 'shared' ? space : null,
                useSharedFolderIcon: true,
                depth: depth + 1,
                selectedUuid: selectedUuid,
                expanded: expanded,
                onToggleFolder: onToggleFolder,
              )),
      ],
    );
  }
}

/// Space 下"知识库"并列子树。挂列出所有 KB(共享 + agent),点击切换右侧内容。
class _KbSubtree extends ConsumerWidget {
  const _KbSubtree({
    required this.kbScope,
    required this.ownerSpaceUuid,
    required this.depth,
    required this.isExpanded,
    required this.isRootSelected,
    required this.onToggle,
    required this.expanded,
    required this.onToggleNode,
  });

  /// 知识库 scope('personal' / 'org')—— knowledge 模块的旧 scope key,非 space uuid。
  final String kbScope;

  /// 该 KB 子树所属 space 的真实 uuid(供选中时回填 selectedSpace,保持其为合法 uuid)。
  final String ownerSpaceUuid;
  final int depth;
  final bool isExpanded;
  final bool isRootSelected;
  final VoidCallback onToggle;
  final Set<String> expanded;
  final void Function(String) onToggleNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncKbList = ref.watch(knowledgeKBListProvider(kbScope));
    final selection = ref.watch(driveSelectionProvider);
    final kbs = asyncKbList.value ?? const <KbItem>[];
    final hasChildren = kbs.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FolderRow(
          icon: CupertinoIcons.book_fill,
          iconColor: const Color(0xFF722ED1),
          label: '知识库',
          depth: depth,
          isExpanded: isExpanded,
          hasChildren: hasChildren,
          isSelected: isRootSelected,
          onToggle: hasChildren ? onToggle : null,
          onTap: () {
            openDriveSelection(
              context,
              ref,
              selection: const DriveSelection(kind: DriveSelectionKind.kbRoot),
              space: kbScope,
            );
            if (hasChildren) onToggle();
          },
        ),
        if (isExpanded)
          ...kbs.map((kb) {
            final foldersAsync = ref.watch(knowledgeFoldersProvider(kb.uuid));
            final folders = foldersAsync.value ?? const <KbFolder>[];
            final rootFolders = folders
                .where((f) => f.parentUuid.isEmpty)
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
            final kbNodeKey = 'kb-${kb.uuid}';
            final kbExpanded = expanded.contains(kbNodeKey);
            final isSelected = selection.kind == DriveSelectionKind.kb &&
                selection.kbUuid == kb.uuid;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FolderRow(
                  icon: CupertinoIcons.folder,
                  iconColor: isSelected
                      ? const Color(0xFF165DFF)
                      : const Color(0xFF722ED1),
                  label: kb.name,
                  depth: depth + 1,
                  isExpanded: kbExpanded,
                  hasChildren: rootFolders.isNotEmpty,
                  isSelected: isSelected,
                  onToggle: rootFolders.isNotEmpty
                      ? () => onToggleNode(kbNodeKey)
                      : null,
                  onTap: () {
                    openDriveSelection(
                      context,
                      ref,
                      selection: DriveSelection(
                        kind: DriveSelectionKind.kb,
                        kbUuid: kb.uuid,
                      ),
                      space: kbScope,
                    );
                    if (rootFolders.isNotEmpty) onToggleNode(kbNodeKey);
                  },
                  onSecondaryTapDown: kb.canWrite
                      ? (d) => _showKbContextMenu(
                            context,
                            ref,
                            kb,
                            kbScope,
                            d.globalPosition,
                          )
                      : null,
                ),
                if (kbExpanded)
                  ...rootFolders.map((folder) => _KbFolderTreeItem(
                        kb: kb,
                        folder: folder,
                        allFolders: folders,
                        space: kbScope,
                        depth: depth + 2,
                        selection: selection,
                        expanded: expanded,
                        onToggleNode: onToggleNode,
                      )),
              ],
            );
          }),
      ],
    );
  }
}

Future<void> _showKbContextMenu(
  BuildContext context,
  WidgetRef ref,
  KbItem kb,
  String kbScope,
  Offset globalPosition,
) async {
  final action = await showUiDropdownContextMenu<String>(
    context: context,
    globalPosition: globalPosition,
    menuWidth: 160,
    items: const [
      UiDropdownMenuItem<String>(
        value: 'rename',
        label: '重命名',
        icon: CupertinoIcons.pencil,
      ),
      UiDropdownMenuItem<String>(
        value: 'delete',
        label: '删除',
        icon: CupertinoIcons.delete,
        danger: true,
      ),
    ],
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case 'rename':
      final result = await showUiInputDialog(
        context,
        title: '重命名知识库',
        initialValue: kb.name,
      );
      if (result == null || result.isEmpty || result == kb.name) return;
      try {
        await ref.read(knowledgeServiceProvider).renameKB(
              kbUuid: kb.uuid,
              name: result
            );
        await ref.read(knowledgeKBListProvider(kbScope).notifier).reload();
        showDriveToast('已重命名');
      } catch (e) {
        showDriveToast('重命名失败:$e', error: true);
      }
      break;
    case 'delete':
      final ok = await showUiConfirmDialog(
        context,
        title: '删除知识库',
        description: '确定删除「${kb.name}」吗?知识库中的目录和文档将一并删除。',
        confirmLabel: '删除',
        danger: true,
      );
      if (!ok) return;
      try {
        await ref.read(knowledgeServiceProvider).deleteKB(kbUuid: kb.uuid);
        await ref.read(knowledgeKBListProvider(kbScope).notifier).reload();
        final selection = ref.read(driveSelectionProvider);
        if ((selection.kind == DriveSelectionKind.kb ||
                selection.kind == DriveSelectionKind.kbFolder) &&
            selection.kbUuid == kb.uuid) {
          ref.read(selectedSpaceProvider.notifier).state = kbScope;
          ref.read(driveSelectionProvider.notifier).state =
              const DriveSelection(
            kind: DriveSelectionKind.kbRoot
          );
        }
        showDriveToast('已删除');
      } catch (e) {
        showDriveToast('删除失败:$e', error: true);
      }
      break;
  }
}

class _KbFolderTreeItem extends StatelessWidget {
  const _KbFolderTreeItem({
    required this.kb,
    required this.folder,
    required this.allFolders,
    required this.space,
    required this.depth,
    required this.selection,
    required this.expanded,
    required this.onToggleNode,
  });

  final KbItem kb;
  final KbFolder folder;
  final List<KbFolder> allFolders;
  final String space;
  final int depth;
  final DriveSelection selection;
  final Set<String> expanded;
  final void Function(String) onToggleNode;

  @override
  Widget build(BuildContext context) {
    final children = allFolders
        .where((f) => f.parentUuid == folder.uuid)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final isExpanded = expanded.contains('kb-folder-${folder.uuid}');
    final isSelected = selection.kind == DriveSelectionKind.kbFolder &&
        selection.kbUuid == kb.uuid &&
        selection.kbFolderUuid == folder.uuid;

    return Consumer(builder: (context, ref, _) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FolderRow(
            icon: CupertinoIcons.folder,
            label: folder.name,
            depth: depth,
            isExpanded: isExpanded,
            hasChildren: children.isNotEmpty,
            isSelected: isSelected,
            onToggle: children.isNotEmpty
                ? () => onToggleNode('kb-folder-${folder.uuid}')
                : null,
            onSecondaryTapDown: (d) => _showKbFolderContextMenu(
              context,
              ref,
              kb,
              folder,
              d.globalPosition,
            ),
            onTap: () {
              openDriveSelection(
                context,
                ref,
                selection: DriveSelection(
                  kind: DriveSelectionKind.kbFolder,
                  kbUuid: kb.uuid,
                  kbFolderUuid: folder.uuid,
                ),
                space: space,
              );
              if (children.isNotEmpty) {
                onToggleNode('kb-folder-${folder.uuid}');
              }
            },
          ),
          if (isExpanded)
            ...children.map((child) => _KbFolderTreeItem(
                  kb: kb,
                  folder: child,
                  allFolders: allFolders,
                  space: space,
                  depth: depth + 1,
                  selection: selection,
                  expanded: expanded,
                  onToggleNode: onToggleNode,
                )),
        ],
      );
    });
  }
}

Future<void> _showKbFolderContextMenu(
  BuildContext context,
  WidgetRef ref,
  KbItem kb,
  KbFolder folder,
  Offset globalPosition,
) async {
  final action = await showUiDropdownContextMenu<String>(
    context: context,
    globalPosition: globalPosition,
    menuWidth: 160,
    items: const [
      UiDropdownMenuItem<String>(
        value: 'rename',
        label: '重命名',
        icon: CupertinoIcons.pencil,
      ),
      UiDropdownMenuItem<String>(
        value: 'delete',
        label: '删除',
        icon: CupertinoIcons.delete,
        danger: true,
      ),
    ],
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'rename':
      final result = await showUiInputDialog(
        context,
        title: '重命名知识库目录',
        initialValue: folder.name,
      );
      if (result == null || result.isEmpty || result == folder.name) return;
      try {
        await ref.read(knowledgeServiceProvider).renameFolder(
              kbUuid: kb.uuid,
              folderUuid: folder.uuid,
              name: result,
            );
        await ref.read(knowledgeFoldersProvider(kb.uuid).notifier).reload();
        showDriveToast('已重命名');
      } catch (e) {
        showDriveToast('重命名失败:$e', error: true);
      }
      break;
    case 'delete':
      final ok = await showUiConfirmDialog(
        context,
        title: '删除知识库目录',
        description: '确定删除「${folder.name}」吗?仅空目录可以删除。',
        confirmLabel: '删除',
        danger: true,
      );
      if (!ok) return;
      try {
        await ref.read(knowledgeServiceProvider).deleteFolder(
              kbUuid: kb.uuid,
              folderUuid: folder.uuid
            );
        await ref.read(knowledgeFoldersProvider(kb.uuid).notifier).reload();
        final selection = ref.read(driveSelectionProvider);
        if (selection.kind == DriveSelectionKind.kbFolder &&
            selection.kbFolderUuid == folder.uuid) {
          ref.read(driveSelectionProvider.notifier).state = DriveSelection(
            kind: DriveSelectionKind.kb,
            kbUuid: kb.uuid,
          );
        }
        showDriveToast('已删除');
      } catch (e) {
        showDriveToast('删除失败:$e', error: true);
      }
      break;
  }
}

class _FolderTreeItem extends ConsumerWidget {
  const _FolderTreeItem({
    required this.folder,
    required this.space,
    this.ownerSpace,
    this.useSharedFolderIcon = false,
    required this.depth,
    required this.selectedUuid,
    required this.expanded,
    required this.onToggleFolder,
  });

  final DriveFolder folder;
  final String space;
  final DriveSpace? ownerSpace;
  final bool useSharedFolderIcon;
  final int depth;
  final String selectedUuid;
  final Set<String> expanded;
  final void Function(String) onToggleFolder;

  IconData _iconForFolder(DriveFolder f) {
    switch (f.kind) {
      case 'de_root':
        return CupertinoIcons.folder_fill;
      case 'de_agent':
        return CupertinoIcons.person_circle_fill;
      case 'de_outputs':
        return CupertinoIcons.folder_fill;
      default:
        return CupertinoIcons.folder;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(driveTreeProvider.notifier);
    final children = notifier.childrenOf(space, folder.uuid);
    final hasChildren = children.isNotEmpty;
    final isExpanded = expanded.contains(folder.uuid);
    // 系统目录(de_root / de_agent / de_outputs)不允许重命名/移动/删除
    final canEdit = !folder.isSystem && folder.kind == 'regular';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FolderRow(
          icon: _iconForFolder(folder),
          leadingIcon: useSharedFolderIcon && folder.kind == 'regular'
              ? _SharedFolderIcon(selected: selectedUuid == folder.uuid)
              : null,
          iconColor:
              folder.kind == 'de_outputs' ? const Color(0xFFFA8C16) : null,
          // de_agent 行优先用真实 agent 头像
          avatarUrl: folder.isAgentRoot ? folder.avatarUrl : '',
          label: folder.name,
          depth: depth,
          isExpanded: isExpanded,
          hasChildren: hasChildren,
          isSelected: selectedUuid == folder.uuid,
          onToggle: hasChildren ? () => onToggleFolder(folder.uuid) : null,
          onTap: () {
            openDriveSelection(
              context,
              ref,
              selection: DriveSelection(
                kind: DriveSelectionKind.driveFolder,
                folderUuid: folder.uuid,
              ),
              space: space,
            );
            // 点击行同步展开/折叠(有子节点时)
            if (hasChildren) onToggleFolder(folder.uuid);
          },
          // 桌面右键菜单:共享子目录额外提供权限管理;系统目录不允许。
          onSecondaryTapDown: canEdit
              ? (d) => _showFolderContextMenu(
                    context,
                    ref,
                    folder,
                    space,
                    d.globalPosition,
                    ownerSpace: ownerSpace,
                  )
              : null,
        ),
        if (isExpanded)
          ...children.map((c) => _FolderTreeItem(
                folder: c,
                space: space,
                ownerSpace: ownerSpace,
                useSharedFolderIcon: useSharedFolderIcon,
                depth: depth + 1,
                selectedUuid: selectedUuid,
                expanded: expanded,
                onToggleFolder: onToggleFolder,
              )),
      ],
    );
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    required this.icon,
    required this.label,
    required this.depth,
    required this.isExpanded,
    required this.hasChildren,
    required this.isSelected,
    required this.onTap,
    this.onToggle,
    this.onSecondaryTapDown,
    this.iconColor,
    this.leadingIcon,
    this.avatarUrl = '',
  });

  final IconData icon;
  final String label;
  final int depth;
  final bool isExpanded;
  final bool hasChildren;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;
  final Color? iconColor;
  final Widget? leadingIcon;
  final String avatarUrl;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const selectedBg = Color(0xFFE6F0FF);
    const hoverBg = Color(0xFFF0F2F5);
    const selectedFg = Color(0xFF165DFF);

    final fallbackIcon = Icon(
      widget.icon,
      size: 16,
      color: widget.iconColor ??
          (widget.isSelected ? selectedFg : const Color(0xFF595959)),
    );
    final iconWidget = widget.leadingIcon ??
        (widget.avatarUrl.isNotEmpty
            ? ClipOval(
                child: Image.network(
                  widget.avatarUrl,
                  width: 18,
                  height: 18,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallbackIcon,
                  loadingBuilder: (_, child, progress) =>
                      progress == null ? child : fallbackIcon,
                ),
              )
            : fallbackIcon);

    Color bg = Colors.transparent;
    if (widget.isSelected) {
      bg = selectedBg;
    } else if (_hovered) {
      bg = hoverBg;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.buttons == kSecondaryMouseButton) {
            widget.onSecondaryTapDown?.call(TapDownDetails(
              globalPosition: event.position,
              localPosition: event.localPosition,
              kind: event.kind,
            ));
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: 34,
            padding: EdgeInsets.only(left: 8.0 + widget.depth * 16, right: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: widget.hasChildren
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onToggle,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 10),
                            child: Icon(
                              widget.isExpanded
                                  ? CupertinoIcons.chevron_down
                                  : CupertinoIcons.chevron_right,
                              size: 16,
                              color: const Color(0xFF5C6370),
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 4),
                SizedBox(
                    width: 18, height: 18, child: Center(child: iconWidget)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color: widget.isSelected
                          ? selectedFg
                          : const Color(0xFF1F2329),
                      fontWeight:
                          widget.isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SharedFolderIcon extends StatelessWidget {
  const _SharedFolderIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF165DFF) : const Color(0xFF8C8C8C);
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(CupertinoIcons.folder, size: 17, color: color),
          Positioned(
            left: 5,
            top: 6,
            child: Icon(CupertinoIcons.person_2_fill, size: 8, color: color),
          ),
        ],
      ),
    );
  }
}

// ============================================================
//  桌面右键菜单:权限管理 / 重命名 / 移动 / 删除(只对 regular 目录)
// ============================================================

/// 在侧栏 regular 目录上右键弹菜单。直接复用 driveServiceProvider 调用,
/// 跟 drive_content_view.dart 里的 helper 行为对齐(reloadSpace + invalidate
/// 父目录 contentProvider + 删除时清当前 selection)。
///
/// 位置:用 MediaQuery 屏幕尺寸构造 RelativeRect,避免在 BotToast 等嵌套
/// overlay 场景下 Overlay.of(context).size 不等于屏幕尺寸导致菜单偏到屏幕
/// 右下角的怪异 bug。
Future<void> _showFolderContextMenu(BuildContext context, WidgetRef ref,
    DriveFolder folder, String space, Offset globalPosition,
    {DriveSpace? ownerSpace}) async {
  final showMembers = ownerSpace?.kind == 'shared';
  final action = await showUiDropdownContextMenu<String>(
    context: context,
    globalPosition: globalPosition,
    menuWidth: 170,
    items: [
      if (showMembers)
        const UiDropdownMenuItem<String>(
          value: 'members',
          label: '权限管理',
          icon: CupertinoIcons.person_2,
        ),
      const UiDropdownMenuItem<String>(
          value: 'rename', label: '重命名', icon: CupertinoIcons.pencil),
      const UiDropdownMenuItem<String>(
          value: 'move',
          label: '移动到…',
          icon: CupertinoIcons.arrow_right_arrow_left),
      const UiDropdownMenuItem<String>(
          value: 'delete',
          label: '删除',
          icon: CupertinoIcons.delete,
          danger: true),
    ],
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'members':
      if (ownerSpace != null) {
        await showDriveFolderMembersDialog(context, ref, ownerSpace, folder);
      }
      break;
    case 'rename':
      await _renameFolderInline(context, ref, folder, space);
      break;
    case 'move':
      await _moveFolderInline(context, ref, folder, space);
      break;
    case 'delete':
      await _deleteFolderInline(context, ref, folder, space);
      break;
  }
}

Future<void> _renameFolderInline(BuildContext context, WidgetRef ref,
    DriveFolder folder, String space) async {
  final result = await showUiInputDialog(
    context,
    title: '重命名目录',
    initialValue: folder.name,
  );
  if (result == null || result.isEmpty || result == folder.name) return;
  try {
    await ref
        .read(driveServiceProvider)
        .renameFolder(folderUuid: folder.uuid, name: result);
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    if (folder.parentId.isNotEmpty) {
      ref.invalidate(driveContentProvider(folder.parentId));
    }
    showDriveToast('已重命名');
  } catch (e) {
    showDriveToast('重命名失败:$e', error: true);
  }
}

Future<void> _moveFolderInline(BuildContext context, WidgetRef ref,
    DriveFolder folder, String space) async {
  final notifier = ref.read(driveTreeProvider.notifier);
  final excludes = <String>[folder.uuid];
  final frontier = <String>[folder.uuid];
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final p in frontier) {
      for (final c in notifier.childrenOf(space, p)) {
        excludes.add(c.uuid);
        next.add(c.uuid);
      }
    }
    frontier
      ..clear()
      ..addAll(next);
  }
  final targetUuid = await showFolderPickerDialog(context, ref,
      title: '移动目录到…', excludeUuids: excludes);
  if (targetUuid == null) return;
  try {
    await ref.read(driveServiceProvider).moveFolder(
          folderUuid: folder.uuid,
          newParentUuid: targetUuid
        );
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    if (folder.parentId.isNotEmpty) {
      ref.invalidate(driveContentProvider(folder.parentId));
    }
    if (targetUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(targetUuid));
    }
    showDriveToast('已移动');
  } catch (e) {
    showDriveToast('移动失败:$e', error: true);
  }
}

Future<void> _deleteFolderInline(BuildContext context, WidgetRef ref,
    DriveFolder folder, String space) async {
  final ok = await showUiConfirmDialog(
    context,
    title: '删除目录',
    description: '确定删除「${folder.name}」吗?目录及其下所有内容将一并删除。',
    confirmLabel: '删除',
    danger: true,
  );
  if (!ok) return;
  try {
    await ref.read(driveServiceProvider).deleteFolder(folder.uuid);
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    if (folder.parentId.isNotEmpty) {
      ref.invalidate(driveContentProvider(folder.parentId));
    }
    final selection = ref.read(driveSelectionProvider);
    if (selection.kind == DriveSelectionKind.driveFolder &&
        selection.folderUuid == folder.uuid) {
      ref.read(driveSelectionProvider.notifier).state = DriveSelection.empty;
    }
    showDriveToast('已删除');
  } catch (e) {
    showDriveToast('删除失败:$e', error: true);
  }
}

// ============================================================
//  共享文件夹右键菜单(F06 基础设置 slice):权限管理 / 重命名 / 删除。
//  仅 `kind='shared'` 的 space 暴露,legacy tenant/department 不显示。
//  权限完全以后端 manager+ 鉴权为准。
// ============================================================

Future<void> _showSharedSpaceContextMenu(
  BuildContext context,
  WidgetRef ref,
  DriveSpace space,
  Offset globalPosition,
) async {
  final action = await showUiDropdownContextMenu<String>(
    context: context,
    globalPosition: globalPosition,
    menuWidth: 170,
    items: const [
      UiDropdownMenuItem<String>(
        value: 'members',
        label: '权限管理',
        icon: CupertinoIcons.person_2,
      ),
      UiDropdownMenuItem<String>(
        value: 'rename',
        label: '重命名',
        icon: CupertinoIcons.pencil,
      ),
      UiDropdownMenuItem<String>(
        value: 'delete',
        label: '删除',
        icon: CupertinoIcons.delete,
        danger: true,
      ),
    ],
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'members':
      await showDriveSpaceMembersDialog(context, ref, space);
      break;
    case 'rename':
      await _renameSharedSpaceInline(context, ref, space);
      break;
    case 'delete':
      await _deleteSharedSpaceInline(context, ref, space);
      break;
  }
}

Future<void> _renameSharedSpaceInline(
    BuildContext context, WidgetRef ref, DriveSpace space) async {
  final result = await showUiInputDialog(
    context,
    hintText: '请输入共享文件夹名称',
    title: '重命名共享文件夹',
    initialValue: space.displayName,
  );
  if (result == null || result.isEmpty || result == space.name) return;
  try {
    await ref.read(driveServiceProvider).updateSharedSpace(
          spaceUuid: space.uuid,
          name: result,
          description: space.description,
        );
    ref.invalidate(driveTreeProvider);
    ref.invalidate(driveRootFilesProvider(space.uuid));
    showDriveToast('已重命名');
  } catch (e) {
    showDriveToast('重命名失败:$e', error: true);
  }
}

Future<void> _deleteSharedSpaceInline(
    BuildContext context, WidgetRef ref, DriveSpace space) async {
  final ok = await showUiConfirmDialog(
    context,
    title: '删除共享文件夹',
    description: '确定删除「${space.displayName}」吗?删除后该共享文件夹会从共享空间中隐藏。',
    confirmLabel: '删除',
    danger: true,
  );
  if (!ok) return;
  try {
    await ref.read(driveServiceProvider).deleteSharedSpace(space.uuid);
    final selectedSpace = ref.read(selectedSpaceProvider);
    if (selectedSpace == space.uuid) {
      ref.read(selectedSpaceProvider.notifier).state = '';
      ref.read(driveSelectionProvider.notifier).state = DriveSelection.empty;
    }
    ref.invalidate(driveTreeProvider);
    ref.invalidate(driveRootFilesProvider(space.uuid));
    showDriveToast('已删除');
  } catch (e) {
    showDriveToast('删除失败:$e', error: true);
  }
}
