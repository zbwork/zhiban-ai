import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_icon.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 选择 N 个云盘文件的对话框。两栏:
///   左:目录树(只列 regular + 系统目录,可点开看)
///   右:选中目录下的文件,带 checkbox 多选
///
/// 用于:
///   - KB "从云盘加入" 入口(只用 uuid)
///   - chat 输入框 "从云盘选择" 入口(需要 name/mime/size 直接构造 ChatFileItem,
///     不必再回查接口)
/// 返回完整 [DriveFile] 列表(取消返回 null)。调用方按需 map 出 uuid。
///
/// 注意:dialog 子树要显式带 ProviderScope,见 folder_picker.dart 注释。
Future<List<DriveFile>?> showDriveFilePicker(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择云盘文件',
  String? subtitle,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (PlatformUtils.isMobile) {
    return showModalBottomSheet<List<DriveFile>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => UncontrolledProviderScope(
        container: container,
        child: _DriveFilePickerDialog(title: title, subtitle: subtitle),
      ),
    );
  }
  return showDialog<List<DriveFile>>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => UncontrolledProviderScope(
      container: container,
      child: _DriveFilePickerDialog(title: title, subtitle: subtitle),
    ),
  );
}

class _DriveFilePickerDialog extends ConsumerStatefulWidget {
  const _DriveFilePickerDialog({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  ConsumerState<_DriveFilePickerDialog> createState() =>
      _DriveFilePickerDialogState();
}

class _DriveFilePickerDialogState
    extends ConsumerState<_DriveFilePickerDialog> {
  // 当前选中空间根 uuid('' = 未选中任何空间)。来自 bootstrap 的真实 space_uuid。
  String _spaceUuid = '';
  // 选中空间是否个人空间:决定面包屑前缀(我的空间 vs 共享空间 / <name>)。
  bool _isPersonalSpace = false;
  // 选中空间的显示名(共享空间面包屑用)。
  String _spaceName = '';
  // 当前选中目录 uuid('' = 选中的是空间根,右侧展示 root files)。
  String _currentFolderUuid = '';
  // 已展开的"节点 key"。空间根用 `space-<uuid>`,共享分组用 `shared-group`,
  // 目录用 folder.uuid。
  final Set<String> _expanded = <String>{};
  // 首次拿到 bootstrap 后只 seed 一次默认选中/展开(默认选「我的空间」根)。
  bool _seededDefault = false;
  // uuid → 完整 DriveFile。用 LinkedHashMap 保证返回顺序 = 用户勾选顺序。
  final Map<String, DriveFile> _selectedFiles = <String, DriveFile>{};
  // 移动端：目录树是否展开
  bool _treeExpanded = true;

  String _query = '';
  // true = 按修改日期升序,false = 降序。
  bool _sortAsc = false;

  void _toggle(String key) => setState(() {
        if (_expanded.contains(key)) {
          _expanded.remove(key);
        } else {
          _expanded.add(key);
        }
      });

  void _onPickSpaceRoot(_SpaceCtx space) {
    setState(() {
      _spaceUuid = space.uuid;
      _isPersonalSpace = space.isPersonal;
      _spaceName = space.name;
      _currentFolderUuid = '';
      if (PlatformUtils.isMobile) _treeExpanded = false;
    });
  }

  void _onPickFolder(_SpaceCtx space, String folderUuid) {
    setState(() {
      _spaceUuid = space.uuid;
      _isPersonalSpace = space.isPersonal;
      _spaceName = space.name;
      _currentFolderUuid = folderUuid;
      if (PlatformUtils.isMobile && folderUuid.isNotEmpty) {
        _treeExpanded = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(driveTreeProvider);
    final isMobile = PlatformUtils.isMobile;

    // bootstrap 解析后只 seed 一次:默认展开共享分组 + 「我的空间」根,并默认选中
    // 「我的空间」根(右侧立即展示个人空间根目录文件,而非默认提示)。
    final treeState = treeAsync.value;
    if (treeState != null && !_seededDefault) {
      _seededDefault = true;
      _expanded.add('shared-group');
      final personal = treeState.personal;
      if (personal != null && personal.uuid.isNotEmpty) {
        _expanded.add('space-${personal.uuid}');
        _spaceUuid = personal.uuid;
        _isPersonalSpace = true;
        _spaceName = personal.displayName;
      }
    }

    final fileListPane = _FileListPane(
      spaceUuid: _spaceUuid,
      isPersonal: _isPersonalSpace,
      spaceName: _spaceName,
      folderUuid: _currentFolderUuid,
      query: _query,
      sortAsc: _sortAsc,
      selectedCount: _selectedFiles.length,
      selectedFileUuids: _selectedFiles.keys.toSet(),
      onQueryChanged: (v) => setState(() => _query = v),
      onToggleSort: () => setState(() => _sortAsc = !_sortAsc),
      onToggle: (file) => setState(() {
        if (_selectedFiles.containsKey(file.uuid)) {
          _selectedFiles.remove(file.uuid);
        } else {
          _selectedFiles[file.uuid] = file;
        }
      }),
    );

    final folderTreePane = _FolderTreePane(
      selectedSpaceUuid: _spaceUuid,
      currentFolderUuid: _currentFolderUuid,
      expanded: _expanded,
      onToggle: _toggle,
      onPickSpaceRoot: _onPickSpaceRoot,
      onPickFolder: _onPickFolder,
    );

    if (isMobile) {
      return DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            // drag handle
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFDDE2EA),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _buildHeader(context),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            treeAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: CupertinoActivityIndicator(radius: 12),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(32),
                child: Text('加载失败:$e'),
              ),
              data: (_) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // collapsible folder tree header
                  InkWell(
                    onTap: () => setState(() => _treeExpanded = !_treeExpanded),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      color: const Color(0xFFF7F8FA),
                      child: Row(
                        children: [
                          const Icon(CupertinoIcons.folder,
                              size: 15, color: Color(0xFF595959)),
                          const SizedBox(width: 6),
                          const Text(
                            '选择目录',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1F2329),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_spaceUuid.isNotEmpty)
                            Expanded(
                              child: Text(
                                _isPersonalSpace
                                    ? '我的空间'
                                    : '共享空间 / $_spaceName',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF165DFF),
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                          Icon(
                            _treeExpanded
                                ? CupertinoIcons.chevron_up
                                : CupertinoIcons.chevron_down,
                            size: 14,
                            color: const Color(0xFF8C8C8C),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_treeExpanded)
                    SizedBox(
                      height: 220,
                      child: folderTreePane
                    ),
                  const Divider(height: 1, color: Color(0xFFF0F0F0)),
                ],
              ),
            ),
            Expanded(child: fileListPane),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            _buildFooter(context),
          ],
        ),
      );
    }

    return UiPickerDialog(
      size: UiDialogSize.wide,
      maxHeight: 620,
      child: SizedBox(
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            Expanded(
              child: treeAsync.when(
                loading: () =>
                    const Center(child: CupertinoActivityIndicator(radius: 12)),
                error: (e, _) => Center(child: Text('加载失败:$e')),
                data: (_) => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            right:
                                BorderSide(color: Color(0xFFF0F0F0), width: 1),
                          ),
                        ),
                        child: folderTreePane,
                      ),
                    ),
                    Expanded(child: fileListPane),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 20, 12),
      child: UiSheetHeader(
        title: widget.title,
        subtitle: (widget.subtitle ?? '').isEmpty ? null : widget.subtitle,
        // 统一使用 UiSheetHeader 的关闭按钮交互与样式，和其它弹框保持一致。
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final hasSelection = _selectedFiles.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF595959),
              textStyle: const TextStyle(fontSize: 14),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF165DFF),
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: hasSelection
                ? () => Navigator.pop(context, _selectedFiles.values.toList())
                : null,
            child: Text('确定 (${_selectedFiles.length})'),
          ),
        ],
      ),
    );
  }
}

/// 选中目标所属空间的上下文。folder 选中时一并带上,供右侧面包屑前缀
/// (我的空间 / 共享空间 / 空间名)与取数使用。
class _SpaceCtx {
  const _SpaceCtx({
    required this.uuid,
    required this.isPersonal,
    required this.name,
  });

  final String uuid;
  final bool isPersonal;
  final String name;
}

/// 目录树面板。结构与云盘主侧栏 (`drive_sidebar.dart`) 一致:
///   - 「我的空间」:真实 personal space,可点选(根)/可展开(目录树)
///   - 「共享空间」:虚拟分组,展开后列出用户可见的真实 shared spaces;
///     每个 shared space 可点选(空间根)/可展开(目录树)
///   - Space 下递归渲染 drive_folders(系统目录 + 用户自建)
/// 不显示"知识库 / 最近使用 / 回收站":picker 只用来选 drive_files。
/// 全程用真实 space_uuid 取数(bootstrap.personal.uuid / orgSpaces[].uuid),
/// 不再用 legacy 'personal'/'org' coarse key。
class _FolderTreePane extends ConsumerWidget {
  const _FolderTreePane({
    required this.selectedSpaceUuid,
    required this.currentFolderUuid,
    required this.expanded,
    required this.onToggle,
    required this.onPickSpaceRoot,
    required this.onPickFolder,
  });

  final String selectedSpaceUuid;
  final String currentFolderUuid;
  final Set<String> expanded;
  final void Function(String key) onToggle;
  final void Function(_SpaceCtx space) onPickSpaceRoot;
  final void Function(_SpaceCtx space, String folderUuid) onPickFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(driveTreeProvider).value;
    final personal = state?.personal;
    final orgSpaces = state?.orgSpaces ?? const <DriveSpace>[];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      children: [
        if (personal != null)
          _SpaceNode(
            space: _SpaceCtx(
              uuid: personal.uuid,
              isPersonal: true,
              name: '我的空间',
            ),
            label: '我的空间',
            icon: CupertinoIcons.home,
            depth: 0,
            selectedSpaceUuid: selectedSpaceUuid,
            currentFolderUuid: currentFolderUuid,
            expanded: expanded,
            onToggle: onToggle,
            onPickSpaceRoot: onPickSpaceRoot,
            onPickFolder: onPickFolder,
          ),
        _SharedGroupNode(
          orgSpaces: orgSpaces,
          selectedSpaceUuid: selectedSpaceUuid,
          currentFolderUuid: currentFolderUuid,
          expanded: expanded,
          onToggle: onToggle,
          onPickSpaceRoot: onPickSpaceRoot,
          onPickFolder: onPickFolder,
        ),
      ],
    );
  }
}

/// 「共享空间」虚拟分组:本身不可选(只展开/折叠),展开后列出真实 shared spaces。
class _SharedGroupNode extends StatelessWidget {
  const _SharedGroupNode({
    required this.orgSpaces,
    required this.selectedSpaceUuid,
    required this.currentFolderUuid,
    required this.expanded,
    required this.onToggle,
    required this.onPickSpaceRoot,
    required this.onPickFolder,
  });

  final List<DriveSpace> orgSpaces;
  final String selectedSpaceUuid;
  final String currentFolderUuid;
  final Set<String> expanded;
  final void Function(String key) onToggle;
  final void Function(_SpaceCtx space) onPickSpaceRoot;
  final void Function(_SpaceCtx space, String folderUuid) onPickFolder;

  static const String _kGroupKey = 'shared-group';

  @override
  Widget build(BuildContext context) {
    final isExpanded = expanded.contains(_kGroupKey);
    final hasSpaces = orgSpaces.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TreeRow(
          icon: CupertinoIcons.building_2_fill,
          label: '共享空间',
          depth: 0,
          hasChildren: hasSpaces,
          isExpanded: isExpanded,
          isSelected: false,
          onToggle: hasSpaces ? () => onToggle(_kGroupKey) : null,
          onTap: () => onToggle(_kGroupKey),
        ),
        if (isExpanded)
          for (final sp in orgSpaces)
            _SpaceNode(
              space: _SpaceCtx(
                uuid: sp.uuid,
                isPersonal: false,
                name: sp.displayName,
              ),
              label: sp.displayName,
              icon: CupertinoIcons.folder_fill,
              depth: 1,
              selectedSpaceUuid: selectedSpaceUuid,
              currentFolderUuid: currentFolderUuid,
              expanded: expanded,
              onToggle: onToggle,
              onPickSpaceRoot: onPickSpaceRoot,
              onPickFolder: onPickFolder,
            ),
      ],
    );
  }
}

/// 一个可点选(空间根)+ 可展开(目录树)的空间节点。
/// 用于「我的空间」(depth 0)与每个共享空间(depth 1)。
class _SpaceNode extends ConsumerWidget {
  const _SpaceNode({
    required this.space,
    required this.label,
    required this.icon,
    required this.depth,
    required this.selectedSpaceUuid,
    required this.currentFolderUuid,
    required this.expanded,
    required this.onToggle,
    required this.onPickSpaceRoot,
    required this.onPickFolder,
  });

  final _SpaceCtx space;
  final String label;
  final IconData icon;
  final int depth;
  final String selectedSpaceUuid;
  final String currentFolderUuid;
  final Set<String> expanded;
  final void Function(String key) onToggle;
  final void Function(_SpaceCtx space) onPickSpaceRoot;
  final void Function(_SpaceCtx space, String folderUuid) onPickFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(driveTreeProvider.notifier);
    final rootFolders = notifier.rootFoldersOf(space.uuid);
    final nodeKey = 'space-${space.uuid}';
    final isExpanded = expanded.contains(nodeKey);
    // 空间根选中:选中的是本空间且未下钻到任何目录。
    final isSelected =
        selectedSpaceUuid == space.uuid && currentFolderUuid.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TreeRow(
          icon: icon,
          label: label,
          depth: depth,
          hasChildren: rootFolders.isNotEmpty,
          isExpanded: isExpanded,
          isSelected: isSelected,
          onToggle: rootFolders.isNotEmpty ? () => onToggle(nodeKey) : null,
          onTap: () {
            onPickSpaceRoot(space);
            if (rootFolders.isNotEmpty && !isExpanded) onToggle(nodeKey);
          },
        ),
        if (isExpanded)
          for (final f in rootFolders)
            _FolderNode(
              folder: f,
              space: space,
              depth: depth + 1,
              currentFolderUuid: currentFolderUuid,
              expanded: expanded,
              onToggle: onToggle,
              onPickFolder: onPickFolder,
            ),
      ],
    );
  }
}

class _FolderNode extends ConsumerWidget {
  const _FolderNode({
    required this.folder,
    required this.space,
    required this.depth,
    required this.currentFolderUuid,
    required this.expanded,
    required this.onToggle,
    required this.onPickFolder,
  });

  final DriveFolder folder;
  final _SpaceCtx space;
  final int depth;
  final String currentFolderUuid;
  final Set<String> expanded;
  final void Function(String key) onToggle;
  final void Function(_SpaceCtx space, String folderUuid) onPickFolder;

  IconData _iconFor(DriveFolder f) {
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
    final children = notifier.childrenOf(space.uuid, folder.uuid);
    final hasChildren = children.isNotEmpty;
    final isExpanded = expanded.contains(folder.uuid);
    final isSelected = folder.uuid == currentFolderUuid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TreeRow(
          icon: _iconFor(folder),
          iconColor:
              folder.kind == 'de_outputs' ? const Color(0xFFFA8C16) : null,
          label: folder.name,
          depth: depth,
          hasChildren: hasChildren,
          isExpanded: isExpanded,
          isSelected: isSelected,
          onToggle: hasChildren ? () => onToggle(folder.uuid) : null,
          onTap: () {
            onPickFolder(space, folder.uuid);
            if (hasChildren && !isExpanded) onToggle(folder.uuid);
          },
        ),
        if (isExpanded)
          for (final c in children)
            _FolderNode(
              folder: c,
              space: space,
              depth: depth + 1,
              currentFolderUuid: currentFolderUuid,
              expanded: expanded,
              onToggle: onToggle,
              onPickFolder: onPickFolder,
            ),
      ],
    );
  }
}

/// 自带的轻量树行,与 `drive_sidebar.dart::_FolderRow` 视觉对齐,
/// 但精简掉了 avatar / 右键 / 编辑等 picker 用不到的能力。
class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.icon,
    required this.label,
    required this.depth,
    required this.hasChildren,
    required this.isExpanded,
    required this.isSelected,
    required this.onTap,
    this.onToggle,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final int depth;
  final bool hasChildren;
  final bool isExpanded;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    const selectedBg = Color(0xFFE6F0FF);
    const selectedFg = Color(0xFF165DFF);
    final fg = isSelected ? selectedFg : const Color(0xFF1F2329);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: EdgeInsets.only(
            left: 8.0 + depth * 16.0,
            right: 8,
            top: 6,
            bottom: 6,
          ),
          decoration: BoxDecoration(
            color: isSelected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: hasChildren
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onToggle,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 8),
                          child: Icon(
                            isExpanded
                                ? CupertinoIcons.chevron_down
                                : CupertinoIcons.chevron_right,
                            size: 15,
                            color: const Color(0xFF5C6370),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
              Icon(
                icon,
                size: 16,
                color: iconColor ??
                    (isSelected ? selectedFg : const Color(0xFF595959)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: fg,
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

class _FileListPane extends ConsumerWidget {
  const _FileListPane({
    required this.spaceUuid,
    required this.isPersonal,
    required this.spaceName,
    required this.folderUuid,
    required this.query,
    required this.sortAsc,
    required this.selectedCount,
    required this.selectedFileUuids,
    required this.onQueryChanged,
    required this.onToggleSort,
    required this.onToggle,
  });

  final String spaceUuid;
  final bool isPersonal;
  final String spaceName;
  final String folderUuid;
  final String query;
  final bool sortAsc;
  final int selectedCount;
  final Set<String> selectedFileUuids;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onToggleSort;
  final ValueChanged<DriveFile> onToggle;

  /// 面包屑:空间前缀(我的空间 / 共享空间 / 空间名)+ 目录路径。
  /// 未选中任何空间时返回空(toolbar 不显示路径)。
  List<String> _breadcrumb(WidgetRef ref) {
    if (spaceUuid.isEmpty) return const [];
    final prefix = isPersonal ? <String>['我的空间'] : <String>['共享空间', spaceName];
    if (folderUuid.isEmpty) return prefix;
    final notifier = ref.read(driveTreeProvider.notifier);
    final names = <String>[];
    var cur = notifier.findFolder(folderUuid);
    var guard = 0;
    while (cur != null && guard++ < 32) {
      names.insert(0, cur.name);
      if (cur.parentId.isEmpty) break;
      cur = notifier.findFolder(cur.parentId);
    }
    return [...prefix, ...names];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crumbs = _breadcrumb(ref);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(context, crumbs),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        _buildListHeader(),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        Expanded(child: _buildList(ref)),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, List<String> crumbs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          const Icon(CupertinoIcons.folder, size: 16, color: Color(0xFF8C8C8C)),
          const SizedBox(width: 6),
          Expanded(child: _Breadcrumb(crumbs: crumbs)),
          const SizedBox(width: 12),
          _SearchBox(value: query, onChanged: onQueryChanged),
          const SizedBox(width: 8),
          _IconBtn(
            tooltip: sortAsc ? '修改日期 升序' : '修改日期 降序',
            icon: sortAsc ? Icons.swap_vert : Icons.swap_vert,
            onTap: onToggleSort,
          ),
          const SizedBox(width: 12),
          Text(
            '已选 $selectedCount 项',
            style: const TextStyle(fontSize: 13, color: Color(0xFF8C8C8C)),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          const SizedBox(width: 28),
          const Expanded(
            child: Text('文件名',
                style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF8C8C8C),
                    fontWeight: FontWeight.w500)),
          ),
          InkWell(
            onTap: onToggleSort,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('修改日期',
                      style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF8C8C8C),
                          fontWeight: FontWeight.w500)),
                  const SizedBox(width: 2),
                  Icon(
                    sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 13,
                    color: const Color(0xFF8C8C8C),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildList(WidgetRef ref) {
    // 未选中任何空间 → 占位。
    if (spaceUuid.isEmpty) {
      return const Center(
        child:
            Text('左侧选择空间或目录查看文件', style: TextStyle(color: Color(0xFF8C8C8C))),
      );
    }
    // 选中目录 → 目录 children;选中空间根(folderUuid 为空) → 该空间 root files。
    final AsyncValue<List<DriveFile>> filesAsync = folderUuid.isNotEmpty
        ? ref
            .watch(driveContentProvider(folderUuid))
            .whenData((s) => s.children?.files ?? const <DriveFile>[])
        : ref.watch(driveRootFilesProvider(spaceUuid));
    return filesAsync.when(
      loading: () =>
          const Center(child: CupertinoActivityIndicator(radius: 12)),
      error: (e, _) => Center(child: Text('加载失败:$e')),
      data: (source) {
        var files = List<DriveFile>.from(source);
        if (query.trim().isNotEmpty) {
          final q = query.trim().toLowerCase();
          files = files.where((f) => f.name.toLowerCase().contains(q)).toList();
        }
        files.sort((a, b) => sortAsc
            ? a.updatedAt.compareTo(b.updatedAt)
            : b.updatedAt.compareTo(a.updatedAt));
        if (files.isEmpty) {
          return Center(
            child: Text(
              folderUuid.isEmpty ? '该空间根目录还没有文件' : '该目录下没有文件',
              style: const TextStyle(color: Color(0xFF8C8C8C)),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: files.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFFF5F5F5)),
          itemBuilder: (_, i) {
            final f = files[i];
            final selected = selectedFileUuids.contains(f.uuid);
            return _FileRow(
              file: f,
              selected: selected,
              onTap: () => onToggle(f),
            );
          },
        );
      },
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.crumbs});
  final List<String> crumbs;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < crumbs.length; i++) {
      final isLast = i == crumbs.length - 1;
      spans.add(TextSpan(
        text: crumbs[i],
        style: TextStyle(
          fontSize: 14,
          color: isLast ? const Color(0xFF165DFF) : const Color(0xFF595959),
          fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
        ),
      ));
      if (!isLast) {
        spans.add(const TextSpan(
          text: '  /  ',
          style: TextStyle(fontSize: 13, color: Color(0xFFBFBFBF)),
        ));
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SearchBox extends StatefulWidget {
  const _SearchBox({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: UiSearchField(
        hintText: '搜索文件',
        controller: _ctrl,
        onChanged: widget.onChanged,
        borderRadius: 6,
        showBorder: false,
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 18, color: const Color(0xFF595959)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.onTap,
  });
  final DriveFile file;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: widget.selected
              ? const Color(0xFFF0F6FF)
              : (_hover ? const Color(0xFFFAFAFA) : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: _CheckBox(checked: widget.selected),
              ),
              const SizedBox(width: 10),
              DriveFileIcon(
                mimeType: f.mimeType,
                name: f.name,
                fileUuid: f.uuid,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF1F2329),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${f.sizeDisplay} · ${f.typeDisplay}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8C8C8C),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _formatDate(f.updatedAt),
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8C8C8C)
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final l = dt.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${pad(l.month)}-${pad(l.day)} '
        '${pad(l.hour)}:${pad(l.minute)}';
  }
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? const Color(0xFF165DFF) : Colors.white,
        border: Border.all(
          color: checked ? const Color(0xFF165DFF) : const Color(0xFFD9D9D9),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      child: checked
          ? const Icon(Icons.check, size: 12, color: Colors.white)
          : null,
    );
  }
}
