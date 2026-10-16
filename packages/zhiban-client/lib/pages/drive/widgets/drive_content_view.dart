import 'package:zhiban_client/network/user_refresh.dart';
import 'package:zhiban_core/utils/error_utils.dart';

import 'package:zhiban_client/pages/drive/widgets/drive_browse_filter.dart';

import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/drive/drive_page.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_chat_import_dialog.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_collaborator_picker.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_picker.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_icon.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_navigation.dart';
import 'package:zhiban_client/pages/drive/widgets/folder_picker.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/drive/widgets/kb_picker.dart';
import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:zhiban_client/pages/knowledge/providers/knowledge_providers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

// 云盘内容区的窄屏断点:低于 520 时切成卡片式信息密度,避免列表列宽溢出。
bool _isDriveNarrow(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 520;

const _driveNarrowContentInset = 16.0;
const _driveNarrowRowInset = 12.0;

const _driveListHeaderStyle = TextStyle(
  fontSize: 15,
  color: Color(0xFF6B7280),
  fontWeight: FontWeight.w700,
);

/// 面包屑一段。[onTap] 为空表示当前所在层级(通常是最后一段)，不可点击。
class _DriveCrumb {
  const _DriveCrumb(this.label, [this.onTap]);
  final String label;
  final VoidCallback? onTap;
}

/// 简单文本面包屑(无点击)，兼容仍未接入跳转目标的调用方。
List<_DriveCrumb> _plainCrumbs(List<String> labels) =>
    labels.map((l) => _DriveCrumb(l)).toList(growable: false);

List<Widget> _driveBreadcrumbWidgets(List<_DriveCrumb> crumbs,
    {bool compact = false}) {
  final children = <Widget>[];
  for (var i = 0; i < crumbs.length; i++) {
    if (i > 0) children.add(_driveCrumbDivider());
    final crumb = crumbs[i];
    final isCurrent = i == crumbs.length - 1;
    final text = Text(
      crumb.label,
      style: TextStyle(
        fontSize: compact ? 12 : 16,
        color: isCurrent ? const Color(0xFF4B5563) : const Color(0xFF7A7F87),
        fontWeight: compact ? FontWeight.w400 : FontWeight.w700,
      ),
    );
    if (crumb.onTap == null) {
      children.add(text);
    } else {
      children.add(MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: crumb.onTap,
          child: text,
        ),
      ));
    }
  }
  return children;
}

Widget _driveCrumbDivider() => const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Icon(
        CupertinoIcons.chevron_right,
        size: 13,
        color: Color(0xFFA6A6A6)
      ),
    );

class _DriveMobileToolbar extends StatelessWidget {
  const _DriveMobileToolbar(
      {required this.breadcrumbs,
      required this.create,
      required this.importButton});
  final Widget breadcrumbs;
  final Widget create;
  final Widget importButton;

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey('drive-mobile-toolbar'),
        children: [
          Expanded(child: breadcrumbs),
          const SizedBox(width: 4),
          create,
          const SizedBox(width: 4),
          importButton,
          const SizedBox(width: 16),
        ],
      );
}

/// 云盘页右侧内容区。
///
/// 根据 [driveSelectionProvider] 的选中类型分流:
///   - drive 目录选中 → 渲染目录面包屑 + 子目录/文件列表
///   - 知识库选中     → 渲染 KB 面包屑 + 文档列表(状态徽章)
///   - 都未选中       → 空状态提示
class DriveContentView extends ConsumerWidget {
  const DriveContentView({
    super.key,
    this.compactHeader = false,
    this.selection,
    this.space,
    this.showUnavailableState = false,
  });

  final bool compactHeader;
  final DriveSelection? selection;
  final String? space;
  final bool showUnavailableState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (showUnavailableState) {
      return _EmptyState(
        message: '云盘暂时无法连接服务器，请检查网络后重试',
        onRetry: () => UserRefresh.run(
            () => ref.refresh(driveTreeProvider.future)).ignore(),
      );
    }
    final DriveSelection effectiveSelection =
        selection ?? ref.watch(driveSelectionProvider);
    final String effectiveSpace = space ?? ref.watch(selectedSpaceProvider);

    switch (effectiveSelection.kind) {
      case DriveSelectionKind.driveRoot:
        return _DriveRootContent(
          compactHeader: compactHeader,
          space: effectiveSpace,
        );
      case DriveSelectionKind.driveFolder:
        return _DriveFolderContent(
          folderUuid: effectiveSelection.folderUuid,
          compactHeader: compactHeader,
          space: effectiveSpace,
        );
      case DriveSelectionKind.kbRoot:
        return _KbRootContent(
          compactHeader: compactHeader,
          space: effectiveSpace,
        );
      case DriveSelectionKind.kb:
        return _KbContent(
          kbUuid: effectiveSelection.kbUuid,
          compactHeader: compactHeader,
          space: effectiveSpace,
        );
      case DriveSelectionKind.kbFolder:
        return _KbContent(
          kbUuid: effectiveSelection.kbUuid,
          kbFolderUuid: effectiveSelection.kbFolderUuid,
          compactHeader: compactHeader,
          space: effectiveSpace,
        );
      case DriveSelectionKind.recent:
        return _RecentFilesContent(compactHeader: compactHeader);
      case DriveSelectionKind.favorite:
        return _FavoriteFilesContent(compactHeader: compactHeader);
      case DriveSelectionKind.recycle:
        return _RecycleContent(compactHeader: compactHeader);
      case DriveSelectionKind.none:
        return const _EmptyState(message: '从左侧选择一个目录或知识库开始');
    }
  }
}

class _DriveRootContent extends ConsumerWidget {
  const _DriveRootContent({
    required this.compactHeader,
    required this.space
  });

  final bool compactHeader;
  final String space;

  bool get _isSharedVirtual => space == 'org';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNarrow = _isDriveNarrow(context);
    final mobileFilter = DriveBrowseFilter.maybeOf(context);
    final hPad = isNarrow ? 16.0 : 32.0;
    final tree = ref.watch(driveTreeProvider).value;
    final rootFolders = _isSharedVirtual
        ? const <DriveFolder>[]
        : ref.read(driveTreeProvider.notifier).rootFoldersOf(space);
    final rootFilesAsync = _isSharedVirtual
        ? const AsyncData<List<DriveFile>>(<DriveFile>[])
        : ref.watch(driveRootFilesProvider(space));
    final orgSpaces = tree?.orgSpaces ?? const <DriveSpace>[];
    final spaceLabel = _driveRootSpaceLabel(tree, space);
    final breadcrumbLabels =
        _driveRootBreadcrumbCrumbs(context, ref, tree, space);
    final createButton = _DriveCreateMenuButton(
      enabled: true,
      onCreateFolder: () => _isSharedVirtual
          ? _showCreateSharedFolderDialog(context, ref)
          : _showNewRootFolderDialog(
              context,
              ref,
              spaceUuid: space,
              spaceLabel: spaceLabel,
            ),
      onCreateDoc: () => showDriveToast('新建文档功能 M3 上线', error: false),
    );
    final importButton = _DriveImportMenuButton(
      enabled: true,
      onImportLocal: _isSharedVirtual
          ? () => showDriveToast('请先进入一个共享文件夹后上传文件')
          : () => _pickAndUploadToSpaceRoot(
                context,
                ref,
                spaceUuid: space
              ),
      onImportLocalFolder: _isSharedVirtual || PlatformUtils.isMobile
          ? null
          : () => _pickAndUploadFolderToSpaceRoot(
                context,
                ref,
                spaceUuid: space
              ),
      onImportFromChat: () => showDriveToast('请先进入一个目录后导入聊天文件'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: mobileFilter?.breadcrumbs != null
              ? EdgeInsets.zero
              : EdgeInsets.fromLTRB(
                  hPad, isNarrow ? 4 : 24, hPad, mobileFilter != null ? 0 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mobileFilter?.breadcrumbs != null)
                _DriveMobileToolbar(
                    breadcrumbs: mobileFilter!.breadcrumbs!,
                    create: createButton,
                    importButton: importButton)
              else if (mobileFilter != null) ...[
                Row(children: [
                  if (compactHeader)
                    const Spacer()
                  else
                    Expanded(
                        child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                                children: _driveBreadcrumbWidgets(
                                    breadcrumbLabels,
                                    compact: true)))),
                  createButton,
                  importButton,
                ]),
              ] else if (isNarrow) ...[
                if (!compactHeader) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _driveBreadcrumbWidgets(breadcrumbLabels,
                          compact: isNarrow),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _ResponsiveActions(
                  isNarrow: isNarrow,
                  create: createButton,
                  importButton: importButton,
                ),
              ] else ...[
                Row(
                  children: [
                    if (!compactHeader)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _driveBreadcrumbWidgets(
                              breadcrumbLabels
                            ),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    const SizedBox(width: 16),
                    createButton,
                    const SizedBox(width: 8),
                    importButton,
                  ],
                ),
              ],
            ],
          ),
        ),
        if (mobileFilter != null && !_isSharedVirtual)
          mobileFilter.controls ?? const SizedBox.shrink(),
        Expanded(
          child: _isSharedVirtual
              ? _SharedDriveRootList(spaces: orgSpaces)
              : rootFilesAsync.when(
                  loading: () => const Center(
                      child: CupertinoActivityIndicator(radius: 12)),
                  error: (e, _) => _EmptyState(message: '加载根文件失败:$e'),
                  data: (rootFiles) => _DriveRootList(
                    space: space,
                    folders: rootFolders,
                    files: rootFiles,
                  ),
                ),
        ),
      ],
    );
  }
}

List<String> _driveRootBreadcrumbLabels(DriveTreeState? tree, String space) {
  if (space == 'org') return ['共享空间', '云盘'];
  final personalUuid = tree?.personal?.uuid ?? '';
  if (space == personalUuid) return ['我的空间', '云盘'];
  for (final sp in tree?.orgSpaces ?? const <DriveSpace>[]) {
    if (sp.uuid == space) return ['共享空间', '云盘', sp.displayName];
  }
  final fallback = _driveRootSpaceLabel(tree, space);
  return fallback.split(' / ');
}

/// 只有"具体共享空间"这个 3 段场景才有真正的上一级可跳(回到共享空间列表)；
/// 个人空间/共享空间列表本身已经是最浅层，前两段不可点。
List<_DriveCrumb> _driveRootBreadcrumbCrumbs(
  BuildContext context,
  WidgetRef ref,
  DriveTreeState? tree,
  String space,
) {
  final labels = _driveRootBreadcrumbLabels(tree, space);
  final isSpecificOrgSpace = space != 'org' &&
      (tree?.orgSpaces ?? const <DriveSpace>[]).any(
        (sp) => sp.uuid == space
      );
  if (!isSpecificOrgSpace) return _plainCrumbs(labels);
  void backToSharedList() => openDriveSelection(
        context,
        ref,
        selection: const DriveSelection(kind: DriveSelectionKind.driveRoot),
        space: 'org',
      );
  return [
    for (var i = 0; i < labels.length; i++)
      _DriveCrumb(
        labels[i],
        i < labels.length - 1 ? backToSharedList : null
      ),
  ];
}

String _driveRootSpaceLabel(DriveTreeState? tree, String space) {
  if (space == 'org') return '共享空间 / 云盘';
  final personalUuid = tree?.personal?.uuid ?? '';
  if (space == personalUuid) return '我的空间 / 云盘';
  for (final sp in tree?.orgSpaces ?? const <DriveSpace>[]) {
    if (sp.uuid == space) return '共享空间 / 云盘 / ${sp.displayName}';
  }
  for (final sp in tree?.allSpaces ?? const <DriveSpace>[]) {
    if (sp.uuid == space) return sp.displayName;
  }
  return '我的空间 / 云盘';
}

class _KbRootContent extends ConsumerWidget {
  const _KbRootContent({
    required this.compactHeader,
    required this.space
  });

  final bool compactHeader;
  final String space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = space == 'org' ? 'org' : 'personal';
    final async = ref.watch(knowledgeKBListProvider(scope));
    final isNarrow = _isDriveNarrow(context);
    final breadcrumbs = DriveBrowseFilter.maybeOf(context)?.breadcrumbs;
    final hPad = isNarrow ? 16.0 : 32.0;
    final breadcrumbLabels = _plainCrumbs([
      scope == 'org' ? '共享空间' : '我的空间',
      '知识库',
    ]);
    final createButton = _DriveCreateMenuButton(
      enabled: true,
      folderLabel: '新建知识库',
      docLabel: '新建文档',
      onCreateFolder: () => _showCreateKbDialog(
        context,
        ref,
        scope: scope
      ),
      onCreateDoc: () => showDriveToast('新建文档功能 M3 上线', error: false),
    );
    final importButton = _DriveImportMenuButton(
      enabled: true,
      localLabel: '本地上传',
      chatLabel: '从云盘加入',
      onImportLocal: () => _uploadDocumentFromKbRoot(
        context,
        ref,
        scope: scope
      ),
      onImportFromChat: () => _linkDriveFileFromKbRoot(
        context,
        ref,
        scope: scope
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: breadcrumbs != null
              ? EdgeInsets.zero
              : EdgeInsets.fromLTRB(hPad, isNarrow ? 14 : 24, hPad, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (breadcrumbs != null)
                _DriveMobileToolbar(
                    breadcrumbs: breadcrumbs,
                    create: createButton,
                    importButton: importButton)
              else if (isNarrow) ...[
                if (!compactHeader) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _driveBreadcrumbWidgets(breadcrumbLabels,
                          compact: isNarrow),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _ResponsiveActions(
                  isNarrow: isNarrow,
                  create: createButton,
                  importButton: importButton,
                ),
              ] else ...[
                Row(
                  children: [
                    if (!compactHeader)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _driveBreadcrumbWidgets(
                              breadcrumbLabels
                            ),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    const SizedBox(width: 16),
                    createButton,
                    const SizedBox(width: 8),
                    importButton,
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        Expanded(
          child: async.when(
            loading: () =>
                const Center(child: CupertinoActivityIndicator(radius: 12)),
            error: (e, _) => _EmptyState(message: '加载知识库失败:$e'),
            data: (items) {
              if (items.isEmpty) {
                return _EmptyState(
                  message: scope == 'org' ? '共享空间还没有知识库' : '我的空间还没有知识库',
                );
              }
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 32),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _KbListCard(kb: items[i], scope: scope),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 「最近使用」入口的右侧面板:列出当前用户云盘下最近 N 个文件,
/// 直接复用 [_FileRow] 视觉,但不带勾选 / 多选(查看为主)。
class _RecentFilesContent extends ConsumerWidget {
  const _RecentFilesContent({required this.compactHeader});

  final bool compactHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(driveRecentFilesProvider);
    final tree = ref.watch(driveTreeProvider).value;
    final isNarrow = _isDriveNarrow(context);
    final hPad = isNarrow ? 16.0 : 24.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compactHeader) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, isNarrow ? 14 : 20, hPad, 12),
            child: isNarrow
                ? Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '最近使用',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1F2329),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        splashRadius: 18,
                        icon: const Icon(CupertinoIcons.refresh,
                            size: 18, color: Color(0xFF595959)),
                        onPressed: () => ref
                            .read(driveRecentFilesProvider.notifier)
                            .reload(),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      const Text(
                        '最近使用',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2329),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '刷新',
                        splashRadius: 18,
                        icon: const Icon(CupertinoIcons.refresh,
                            size: 18, color: Color(0xFF595959)),
                        onPressed: () => ref
                            .read(driveRecentFilesProvider.notifier)
                            .reload(),
                      ),
                    ],
                  ),
          ),
        ],
        if (!isNarrow)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: const _RecentFilesTableHeader(),
          ),
        Expanded(
          child: async.when(
            loading: () =>
                const Center(child: CupertinoActivityIndicator(radius: 12)),
            error: (e, _) => Center(
              child: Text('加载失败:$e',
                  style: const TextStyle(color: Color(0xFFE5484D))),
            ),
            data: (files) {
              if (files.isEmpty) {
                return const _EmptyState(message: '云盘还没有最近使用的文件');
              }
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(0, isNarrow ? 6 : 0, 0, 16),
                itemCount: files.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFF5F5F5)),
                itemBuilder: (_, i) => _RecentFileRow(
                  file: files[i],
                  tree: tree,
                  horizontalPadding: hPad,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RecentFilesTableHeader extends StatelessWidget {
  const _RecentFilesTableHeader();

  static const double _locationWidth = 104;
  static const double _ownerWidth = 80;
  static const double _updatedWidth = 150;
  static const double _actionWidth = 48;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEFF1F5))),
      ),
      child: const Row(
        children: [
          Expanded(flex: 5, child: Text('标题', style: _driveListHeaderStyle)),
          SizedBox(
            width: _locationWidth,
            child: Text('位置', style: _driveListHeaderStyle),
          ),
          SizedBox(
            width: _ownerWidth,
            child: Text('所有者', style: _driveListHeaderStyle),
          ),
          SizedBox(
            width: _updatedWidth,
            child: Text('更新时间', style: _driveListHeaderStyle),
          ),
          SizedBox(
            width: _actionWidth,
            child: Text('操作', style: _driveListHeaderStyle),
          ),
        ],
      ),
    );
  }
}

class _RecentFileRow extends ConsumerStatefulWidget {
  const _RecentFileRow({
    required this.file,
    required this.tree,
    required this.horizontalPadding,
  });

  final DriveFile file;
  final DriveTreeState? tree;
  final double horizontalPadding;

  @override
  ConsumerState<_RecentFileRow> createState() => _RecentFileRowState();
}

class _RecentFileRowState extends ConsumerState<_RecentFileRow> {
  bool _hover = false;

  static const double _locationWidth = _RecentFilesTableHeader._locationWidth;
  static const double _ownerWidth = _RecentFilesTableHeader._ownerWidth;
  static const double _updatedWidth = _RecentFilesTableHeader._updatedWidth;
  static const double _actionWidth = _RecentFilesTableHeader._actionWidth;

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${pad(l.month)}-${pad(l.day)} '
        '${pad(l.hour)}:${pad(l.minute)}';
  }

  String _locationLabel() {
    final tree = widget.tree;
    final file = widget.file;
    if (tree == null) return '云盘';
    if (file.driveFolderUuid.isNotEmpty) {
      final folder =
          ref.read(driveTreeProvider.notifier).findFolder(file.driveFolderUuid);
      if (folder != null) return folder.name;
    }
    for (final sp in tree.allSpaces) {
      if (sp.uuid == file.spaceUuid) {
        return sp.isPersonal ? '我的空间' : sp.displayName;
      }
    }
    return '云盘';
  }

  String _ownerLabel() {
    final name = widget.file.ownerDisplayName.trim();
    if (name.isNotEmpty) return name;
    return '-';
  }

  void _refreshAfterMutation({String? targetFolderUuid}) {
    ref.invalidate(driveRecentFilesProvider);
    final folderUuid = widget.file.driveFolderUuid;
    if (folderUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(folderUuid));
    }
    if (targetFolderUuid != null && targetFolderUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(targetFolderUuid));
    }
    if (widget.file.spaceUuid.isNotEmpty) {
      ref.invalidate(driveRootFilesProvider(widget.file.spaceUuid));
    }
  }

  Future<void> _open() async {
    try {
      final url = await ref
          .read(driveServiceProvider)
          .previewUrl(fileUuid: widget.file.uuid);
      if (widget.file.mimeType.startsWith('image/')) {
        if (!mounted) return;
        showImagePreviewRoute<void>(
          context: context,
          useSafeArea: Theme.of(context).platform != TargetPlatform.iOS &&
              Theme.of(context).platform != TargetPlatform.android,
          builder: (_) => UiImagePreviewDialog(
            fileUrl: url.url,
            cacheKey: widget.file.uuid,
          ),
        );
        return;
      }
      final ok = await launchUrl(Uri.parse(url.url),
          mode: LaunchMode.externalApplication);
      if (!ok) showDriveToast('打开失败', error: true);
    } catch (e) {
      showDriveToast('打开失败:$e', error: true);
    }
  }

  Future<void> _rename() async {
    final result = await showUiInputDialog(
      context,
      title: '重命名文件',
      initialValue: widget.file.name,
    );
    if (result == null || result.isEmpty || result == widget.file.name) return;
    try {
      await ref
          .read(driveServiceProvider)
          .renameFile(fileUuid: widget.file.uuid, name: result);
      _refreshAfterMutation();
      showDriveToast('已重命名');
    } catch (e) {
      showDriveToast('重命名失败:$e', error: true);
    }
  }

  Future<void> _move() async {
    final currentFolderUuid = widget.file.driveFolderUuid;
    final targetUuid = await showFolderPickerDialog(
      context,
      ref,
      title: '选择目标目录',
      excludeUuids: [if (currentFolderUuid.isNotEmpty) currentFolderUuid],
    );
    if (targetUuid == null || targetUuid == currentFolderUuid) {
      return;
    }
    try {
      await ref
          .read(driveServiceProvider)
          .moveFile(fileUuid: widget.file.uuid, newFolderUuid: targetUuid);
      _refreshAfterMutation(targetFolderUuid: targetUuid);
      showDriveToast('已移动');
    } catch (e) {
      showDriveToast('移动失败:$e', error: true);
    }
  }

  Future<void> _delete() async {
    final ok = await showUiConfirmDialog(
      context,
      title: '删除文件',
      description: '确定删除「${widget.file.name}」吗?',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await ref.read(driveServiceProvider).deleteFile(widget.file.uuid);
      _refreshAfterMutation();
      showDriveToast('已删除');
    } catch (e) {
      showDriveToast('删除失败:$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final isNarrow = _isDriveNarrow(context);
    final isFavorite = _isResourceFavorite(
      ref.watch(driveFavoritesProvider).value,
      targetKind: 'drive_file',
      targetUuid: f.uuid,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _open,
        child: Container(
          color: _hover ? const Color(0xFFFAFAFA) : Colors.transparent,
          padding: EdgeInsets.symmetric(
              horizontal: isNarrow ? 16 : widget.horizontalPadding,
              vertical: isNarrow ? 10 : 12),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    DriveFileIcon(
                      mimeType: f.mimeType,
                      name: f.name,
                      fileUuid: f.uuid,
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
                                fontSize: 14, color: Color(0xFF1F2329)),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            isNarrow
                                ? '${f.sizeDisplay} · ${_fmtDate(f.updatedAt)}'
                                : '${f.sizeDisplay} · ${f.typeDisplay}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF8C8C8C)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!isNarrow) ...[
                SizedBox(
                  width: _locationWidth,
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.folder,
                          size: 16, color: Color(0xFF8C8C8C)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _locationLabel(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, color: Color(0xFF6B7280)),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: _ownerWidth,
                  child: Text(
                    _ownerLabel(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                  ),
                ),
                SizedBox(
                  width: _updatedWidth,
                  child: Text(
                    _fmtDate(f.updatedAt),
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                  ),
                ),
              ],
              SizedBox(
                width: isNarrow ? 48 : _actionWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: UiDropdownMenu<String>(
                    menuWidth: 180,
                    hoverRadius: 8,
                    items: [
                      const UiDropdownMenuItem(
                        value: 'download',
                        label: '下载',
                        icon: CupertinoIcons.cloud_download,
                      ),
                      UiDropdownMenuItem(
                        value: 'favorite',
                        label: isFavorite ? '取消收藏' : '收藏',
                        icon: isFavorite
                            ? CupertinoIcons.star_fill
                            : CupertinoIcons.star,
                      ),
                      const UiDropdownMenuItem(
                        value: 'rename',
                        label: '重命名',
                        icon: CupertinoIcons.pencil,
                      ),
                      const UiDropdownMenuItem(
                        value: 'move',
                        label: '移动到…',
                        icon: CupertinoIcons.arrow_right_arrow_left,
                      ),
                      const UiDropdownMenuItem(
                        value: 'addToKb',
                        label: '加入知识库…',
                        icon: CupertinoIcons.book,
                      ),
                      const UiDropdownMenuItem(
                        value: 'delete',
                        label: '删除',
                        icon: CupertinoIcons.delete,
                        danger: true,
                      ),
                    ],
                    onSelected: (action) async {
                      switch (action) {
                        case 'download':
                          await _downloadFile(context, ref, f);
                        case 'favorite':
                          await _toggleFavorite(
                            ref,
                            targetKind: 'drive_file',
                            targetUuid: f.uuid,
                            isFavorite: isFavorite,
                          );
                        case 'rename':
                          await _rename();
                        case 'move':
                          await _move();
                        case 'addToKb':
                          await _addToKb(context, ref, f);
                        case 'delete':
                          await _delete();
                      }
                    },
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(CupertinoIcons.ellipsis,
                          size: 16, color: Color(0xFF8C8C8C)),
                    ),
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

class _DriveFolderContent extends ConsumerWidget {
  const _DriveFolderContent({
    required this.folderUuid,
    required this.compactHeader,
    required this.space,
  });

  final String folderUuid;
  final bool compactHeader;
  final String space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = ref.read(driveTreeProvider.notifier).findFolder(folderUuid);
    if (folder == null) {
      return const _EmptyState(message: '目录不存在或已被删除');
    }
    final asyncContent = ref.watch(driveContentProvider(folderUuid));
    final mobileFilter = DriveBrowseFilter.maybeOf(context);
    final canDropHere = !folder.isSystem && folder.isRegular;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(folder: folder, compact: compactHeader, space: space),
        if (mobileFilter != null)
          mobileFilter.controls ?? const SizedBox.shrink(),
        Expanded(
          child: DropTarget(
            onDragDone: canDropHere
                ? (detail) => _uploadDroppedFiles(ref, folder, detail.files)
                : null,
            child: asyncContent.when(
              loading: () =>
                  const Center(child: CupertinoActivityIndicator(radius: 12)),
              error: (e, _) => _EmptyState(message: '加载失败:$e'),
              data: (state) =>
                  _ChildrenList(folder: folder, state: state, space: space),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
//  我的收藏:聚合当前账号收藏的云盘文件与知识库文档。
// ============================================================

class _FavoriteFilesContent extends ConsumerWidget {
  const _FavoriteFilesContent({required this.compactHeader});

  final bool compactHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(driveFavoritesProvider);
    final isNarrow = _isDriveNarrow(context);
    final hPad = isNarrow ? 16.0 : 24.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compactHeader)
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, isNarrow ? 14 : 20, hPad, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '我的收藏',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1F2329),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  splashRadius: 18,
                  icon: const Icon(
                    CupertinoIcons.refresh,
                    size: 18,
                    color: Color(0xFF595959),
                  ),
                  onPressed: () =>
                      ref.read(driveFavoritesProvider.notifier).reload(),
                ),
              ],
            ),
          ),
        if (!isNarrow)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: const _FavoriteFilesTableHeader(),
          ),
        Expanded(
          child: async.when(
            loading: () =>
                const Center(child: CupertinoActivityIndicator(radius: 12)),
            error: (e, _) => Center(
              child: Text(
                '加载收藏失败:$e',
                style: const TextStyle(color: Color(0xFFE5484D)),
              ),
            ),
            data: (items) {
              if (items.isEmpty) {
                return const _EmptyState(message: '还没有收藏文件');
              }
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(0, isNarrow ? 6 : 0, 0, 16),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFF5F5F5)),
                itemBuilder: (_, i) => _FavoriteFileRow(
                  item: items[i],
                  horizontalPadding: hPad
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FavoriteFilesTableHeader extends StatelessWidget {
  const _FavoriteFilesTableHeader();

  static const double sourceWidth = 96;
  static const double favoriteTimeWidth = 150;
  static const double actionWidth = 48;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEFF1F5))),
      ),
      child: const Row(
        children: [
          Expanded(flex: 5, child: Text('名称', style: _driveListHeaderStyle)),
          SizedBox(
            width: sourceWidth,
            child: Text('来源', style: _driveListHeaderStyle),
          ),
          SizedBox(
            width: favoriteTimeWidth,
            child: Text('收藏时间', style: _driveListHeaderStyle),
          ),
          SizedBox(
            width: actionWidth,
            child: Text('操作', style: _driveListHeaderStyle),
          ),
        ],
      ),
    );
  }
}

class _FavoriteFileRow extends ConsumerStatefulWidget {
  const _FavoriteFileRow({
    required this.item,
    required this.horizontalPadding
  });

  final DriveFavoriteItem item;
  final double horizontalPadding;

  @override
  ConsumerState<_FavoriteFileRow> createState() => _FavoriteFileRowState();
}

class _FavoriteFileRowState extends ConsumerState<_FavoriteFileRow> {
  bool _hovered = false;

  DriveFile _driveFile() => DriveFile(
        uuid: widget.item.targetUuid,
        name: widget.item.name,
        mimeType: widget.item.mimeType,
        sizeBytes: widget.item.sizeBytes,
        source: 'favorite',
        spaceUuid: widget.item.spaceUuid,
        driveFolderUuid: widget.item.folderUuid,
        createdAt: widget.item.createdAt,
        updatedAt: widget.item.updatedAt,
      );

  KbDocument _kbDocument() => KbDocument(
        uuid: widget.item.targetUuid,
        kbUuid: widget.item.kbUuid,
        fileUuid: '',
        fileName: widget.item.name,
        kbFolderUuid: widget.item.folderUuid,
        mimeType: widget.item.mimeType,
        sizeBytes: widget.item.sizeBytes,
        source: 'kb_upload',
        status: widget.item.status,
        chunksCount: 0,
        createdAt: widget.item.createdAt,
        updatedAt: widget.item.updatedAt,
      );

  Future<void> _open() async {
    if (widget.item.isDriveFile) {
      await previewDriveFile(context, ref, _driveFile());
      return;
    }
    await _downloadKbDoc(context, ref, _kbDocument());
  }

  Future<void> _remove() async {
    try {
      await ref.read(driveServiceProvider).removeFavorite(
            targetKind: widget.item.targetKind,
            targetUuid: widget.item.targetUuid,
          );
      ref.invalidate(driveFavoritesProvider);
      showDriveToast('已取消收藏');
    } catch (e) {
      showDriveToast('取消收藏失败:$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isNarrow = _isDriveNarrow(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _open,
        child: Container(
          color: _hovered ? const Color(0xFFFAFAFA) : Colors.transparent,
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? 16 : widget.horizontalPadding,
            vertical: 12,
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    DriveFileIcon(
                      mimeType: item.mimeType,
                      name: item.name,
                      fileUuid: item.isDriveFile ? item.targetUuid : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF1F2329),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            isNarrow
                                ? '${item.sizeDisplay} · ${item.sourceLabel}'
                                : item.sizeDisplay,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8C8C8C),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!isNarrow) ...[
                SizedBox(
                  width: _FavoriteFilesTableHeader.sourceWidth,
                  child: Text(
                    item.sourceLabel,
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                  ),
                ),
                SizedBox(
                  width: _FavoriteFilesTableHeader.favoriteTimeWidth,
                  child: Text(
                    _formatFavoriteDate(item.favoritedAt),
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
                  ),
                ),
              ],
              SizedBox(
                width: _FavoriteFilesTableHeader.actionWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: UiDropdownMenu<String>(
                    menuWidth: 160,
                    hoverRadius: 8,
                    items: const [
                      UiDropdownMenuItem(
                        value: 'download',
                        label: '下载',
                        icon: CupertinoIcons.cloud_download,
                      ),
                      UiDropdownMenuItem(
                        value: 'unfavorite',
                        label: '取消收藏',
                        icon: CupertinoIcons.star_fill,
                      ),
                    ],
                    onSelected: (action) async {
                      switch (action) {
                        case 'download':
                          if (item.isDriveFile) {
                            await _downloadFile(context, ref, _driveFile());
                          } else {
                            await _downloadKbDoc(context, ref, _kbDocument());
                          }
                        case 'unfavorite':
                          await _remove();
                      }
                    },
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        CupertinoIcons.ellipsis,
                        size: 16,
                        color: Color(0xFF8C8C8C),
                      ),
                    ),
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

String _formatFavoriteDate(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

// ============================================================
//  回收站(F06 基础设置 slice):列表 + restore + purge
//  manager+ 才能列;客户端**禁止**调用 admin 路径,完全走 /drive/recycle*。
// ============================================================
class _RecycleContent extends ConsumerStatefulWidget {
  const _RecycleContent({required this.compactHeader});
  final bool compactHeader;

  @override
  ConsumerState<_RecycleContent> createState() => _RecycleContentState();
}

class _RecycleContentState extends ConsumerState<_RecycleContent> {
  String? _selectedUuid;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(driveRecycleProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 640 || _isDriveNarrow(context);
        final hPad = isNarrow ? 16.0 : 24.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.compactHeader) ...[
              Padding(
                padding:
                    EdgeInsets.fromLTRB(hPad, isNarrow ? 14 : 20, hPad, 12),
                child: _RecycleHeader(isNarrow: isNarrow),
              ),
            ],
            Padding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              child: _RecycleTableHeader(isNarrow: isNarrow),
            ),
            Expanded(
              child: async.when(
                loading: () =>
                    const Center(child: CupertinoActivityIndicator(radius: 12)),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '加载回收站失败:$e\n(需要 manager+ 权限)',
                      style: const TextStyle(color: Color(0xFFE5484D)),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                data: (items) {
                  if (items.isEmpty) {
                    return const _EmptyState(message: '回收站是空的');
                  }
                  return ListView.builder(
                    padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _RecycleRow(
                      item: items[i],
                      isNarrow: isNarrow,
                      selected: _selectedUuid == items[i].uuid,
                      onSelect: () =>
                          setState(() => _selectedUuid = items[i].uuid),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecycleHeader extends StatelessWidget {
  const _RecycleHeader({required this.isNarrow});

  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    return Text(
      '回收站',
      style: TextStyle(
        fontSize: isNarrow ? 20 : 22,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF1F2329),
      ),
    );
  }
}

class _RecycleTableHeader extends StatelessWidget {
  const _RecycleTableHeader({required this.isNarrow});

  final bool isNarrow;
  static const double _pathWidth = 160;
  static const double _deletedAtWidth = 118;
  static const double _deletedByWidth = 88;
  static const double _sizeWidth = 76;
  static const double _actionWidth = 64;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            const Expanded(
              flex: 5,
              child: Text('名称', style: _driveListHeaderStyle),
            ),
            if (!isNarrow) ...[
              const SizedBox(
                width: _pathWidth,
                child: Text('文件路径', style: _driveListHeaderStyle),
              ),
              const SizedBox(
                width: _deletedAtWidth,
                child: Text('删除时间', style: _driveListHeaderStyle),
              ),
              const SizedBox(
                width: _deletedByWidth,
                child: Text('删除者', style: _driveListHeaderStyle),
              ),
              const SizedBox(
                width: _sizeWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('大小', style: _driveListHeaderStyle),
                ),
              ),
            ],
            SizedBox(
              width: isNarrow ? 52 : _actionWidth,
              child: const Align(
                alignment: Alignment.center,
                child: Text('操作', style: _driveListHeaderStyle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _RecycleAction { restore, purge }

class _RecycleRow extends ConsumerStatefulWidget {
  const _RecycleRow({
    required this.item,
    required this.isNarrow,
    required this.selected,
    required this.onSelect,
  });

  final RecycleItem item;
  final bool isNarrow;
  final bool selected;
  final VoidCallback onSelect;

  @override
  ConsumerState<_RecycleRow> createState() => _RecycleRowState();
}

class _RecycleRowState extends ConsumerState<_RecycleRow> {
  bool _hover = false;
  bool _busy = false;

  static const double _pathWidth = _RecycleTableHeader._pathWidth;
  static const double _deletedAtWidth = _RecycleTableHeader._deletedAtWidth;
  static const double _deletedByWidth = _RecycleTableHeader._deletedByWidth;
  static const double _sizeWidth = _RecycleTableHeader._sizeWidth;
  static const double _actionWidth = _RecycleTableHeader._actionWidth;

  String _fmtDate(DateTime dt, {bool short = false}) {
    final l = dt.toLocal();
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    if (short) {
      final today = DateTime(now.year, now.month, now.day);
      final thatDay = DateTime(l.year, l.month, l.day);
      final diff = today.difference(thatDay).inDays;
      if (diff == 0) return '今天 ${pad(l.hour)}:${pad(l.minute)}';
      if (diff == 1) return '昨天 ${pad(l.hour)}:${pad(l.minute)}';
      return '${l.month}月${l.day}日 ${pad(l.hour)}:${pad(l.minute)}';
    }
    return '${l.year}-${pad(l.month)}-${pad(l.day)} '
        '${pad(l.hour)}:${pad(l.minute)}';
  }

  String _expireHint(DateTime expiresAt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiry = expiresAt.toLocal();
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    final days = expiryDay.difference(today).inDays;
    if (days <= 0) return '今天过期';
    return '$days 天后过期';
  }

  String _deletedByLabel(RecycleItem item) {
    final name = item.deletedByDisplayName.trim();
    if (name.isNotEmpty) return name;
    return '-';
  }

  String _sizeLabel(RecycleItem item) {
    if (item.isFolder) return '-';
    return item.sizeDisplay;
  }

  String _locationPath(RecycleItem item) {
    final path = item.locationPath.trim();
    if (path.isNotEmpty) return path;
    return '云盘';
  }

  Future<void> _showMenu(TapDownDetails details) async {
    widget.onSelect();
    final action = await showUiDropdownContextMenu<_RecycleAction>(
      context: context,
      globalPosition: details.globalPosition,
      menuWidth: 112,
      menuBorderRadius: 8,
      items: const [
        UiDropdownMenuItem(value: _RecycleAction.restore, label: '恢复'),
        UiDropdownMenuItem(
          value: _RecycleAction.purge,
          label: '彻底删除',
          danger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    await _runAction(action);
  }

  Future<void> _runAction(_RecycleAction action) async {
    switch (action) {
      case _RecycleAction.restore:
        await _restore();
        break;
      case _RecycleAction.purge:
        await _purge();
        break;
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(driveServiceProvider).restoreRecycle(widget.item.uuid);
      ref.read(driveRecycleProvider.notifier).removeLocal(widget.item.uuid);
      // 树/最近列表也可能受影响,粗刷一遍。
      ref.invalidate(driveRecentFilesProvider);
      ref.read(driveTreeProvider.notifier).reloadSpace(widget.item.spaceUuid);
      BotToast.showText(text: '已恢复');
    } catch (e) {
      BotToast.showText(text: '恢复失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge() async {
    if (_busy) return;
    final ok = await showUiConfirmDialog(
      context,
      title: '彻底删除',
      description: '将彻底删除「${widget.item.name}」,对象存储与 DB 同时清理,**不可恢复**。继续?',
      confirmLabel: '彻底删除',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await ref.read(driveServiceProvider).purgeRecycle(widget.item.uuid);
      ref.read(driveRecycleProvider.notifier).removeLocal(widget.item.uuid);
      BotToast.showText(text: '已彻底删除');
    } catch (e) {
      BotToast.showText(text: '删除失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        onSecondaryTapDown: _showMenu,
        child: Opacity(
          opacity: _busy ? 0.55 : 1,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.symmetric(
              horizontal: widget.isNarrow ? 12 : 16,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? const Color(0xFFEAF2FF)
                  : (_hover ? const Color(0xFFEEF3FF) : Colors.white),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: widget.selected
                    ? const Color(0xFFA9C3FF)
                    : (_hover
                        ? const Color(0xFFB8CEFF)
                        : const Color(0xFFEEEEEE)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      _RecycleItemIcon(item: it),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF111827),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.isNarrow
                                  ? '${_expireHint(it.expiresAt)} · ${_locationPath(it)}'
                                  : _expireHint(it.expiresAt),
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
                    ],
                  ),
                ),
                if (!widget.isNarrow) ...[
                  SizedBox(
                    width: _pathWidth,
                    child: Text(
                      _locationPath(it),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _deletedAtWidth,
                    child: Text(
                      _fmtDate(it.deletedAtLogical, short: true),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _deletedByWidth,
                    child: Text(
                      _deletedByLabel(it),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _sizeWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _sizeLabel(it),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ),
                ],
                SizedBox(
                  width: widget.isNarrow ? 52 : _actionWidth,
                  child: Align(
                    alignment: Alignment.center,
                    child: UiDropdownMenu<_RecycleAction>(
                      menuWidth: 132,
                      hoverRadius: 8,
                      items: const [
                        UiDropdownMenuItem(
                          value: _RecycleAction.restore,
                          label: '恢复',
                          icon: CupertinoIcons.arrow_counterclockwise,
                        ),
                        UiDropdownMenuItem(
                          value: _RecycleAction.purge,
                          label: '彻底删除',
                          icon: CupertinoIcons.delete,
                          danger: true,
                        ),
                      ],
                      onSelected: (action) async {
                        widget.onSelect();
                        await _runAction(action);
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _hover || widget.selected
                              ? const Color(0xFFEFF4FF)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          CupertinoIcons.ellipsis,
                          size: 17,
                          color: Color(0xFF6B7280),
                        ),
                      ),
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

class _RecycleItemIcon extends ConsumerStatefulWidget {
  const _RecycleItemIcon({required this.item});

  final RecycleItem item;

  @override
  ConsumerState<_RecycleItemIcon> createState() => _RecycleItemIconState();
}

class _RecycleItemIconState extends ConsumerState<_RecycleItemIcon> {
  String? _url;

  RecycleItem get item => widget.item;

  bool get _looksImage {
    if (item.mimeType.startsWith('image/')) return true;
    final lower = item.name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif');
  }

  @override
  void initState() {
    super.initState();
    _url = item.previewUrl.isNotEmpty ? item.previewUrl : null;
    _fetchRecyclePreviewIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _RecycleItemIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.uuid == item.uuid &&
        oldWidget.item.previewUrl == item.previewUrl &&
        oldWidget.item.name == item.name &&
        oldWidget.item.mimeType == item.mimeType) {
      return;
    }
    _url = item.previewUrl.isNotEmpty ? item.previewUrl : null;
    _fetchRecyclePreviewIfNeeded();
  }

  Future<void> _fetchRecyclePreviewIfNeeded() async {
    if (_url != null || !item.isFile || !_looksImage) return;
    try {
      final result =
          await ref.read(driveServiceProvider).recyclePreviewUrl(item.uuid);
      if (!mounted) return;
      if (result.url.isNotEmpty) setState(() => _url = result.url);
    } catch (_) {
      // 旧后端或非图片对象时保持图片类型占位，不打断列表展示。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (item.isFolder) {
      return const Icon(
        CupertinoIcons.folder_fill,
        size: 24,
        color: Color(0xFFFF8A00),
      );
    }
    if (_url != null && _url!.isNotEmpty) {
      return UiNetworkImage(
        imageUrl: _url!,
        width: 36,
        height: 36,
        borderRadius: 6,
        cacheKey: 'recycle:${item.uuid}',
      );
    }
    return DriveFileIcon(
      mimeType: item.mimeType,
      name: item.name,
      size: 36
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.folder_open,
              size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Color(0xFF8C8C8C))),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}

class _ResponsiveActions extends StatelessWidget {
  const _ResponsiveActions({
    required this.isNarrow,
    required this.create,
    required this.importButton,
  });

  final bool isNarrow;
  final Widget create;
  final Widget importButton;

  @override
  Widget build(BuildContext context) {
    if (!isNarrow) {
      return Row(
        children: [
          const Spacer(),
          create,
          const SizedBox(width: 8),
          importButton,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: create),
        const SizedBox(width: 8),
        Expanded(child: importButton),
      ],
    );
  }
}

class _DriveRootList extends StatelessWidget {
  const _DriveRootList({
    required this.space,
    required this.folders,
    required this.files,
  });

  final String space;
  final List<DriveFolder> folders;
  final List<DriveFile> files;

  @override
  Widget build(BuildContext context) {
    final filter = DriveBrowseFilter.maybeOf(context);
    final visibleFolders = folders
        .where((folder) => filter?.matchesFolder(folder.name) ?? true)
        .toList();
    final visibleFiles =
        files.where((file) => filter?.matchesFile(file) ?? true).toList();
    if (visibleFolders.isEmpty && visibleFiles.isEmpty) {
      return _EmptyState(
          message:
              folders.isEmpty && files.isEmpty ? '云盘根目录还是空的' : '已加载内容中没有匹配的文件');
    }
    final isNarrow = _isDriveNarrow(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        isNarrow ? _driveNarrowContentInset - _driveNarrowRowInset : 32,
        isNarrow ? 0 : 8,
        isNarrow ? _driveNarrowContentInset - _driveNarrowRowInset : 32,
        32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _DriveTableHeader(),
          ...visibleFolders.map((folder) => _SubFolderRow(
                space: space,
                folder: folder,
                parentUuid: ''),
              ),
          ...visibleFiles.map((file) => _FileRow(
                file: file,
                location: _DriveLocation.root(spaceUuid: space),
              )),
        ],
      ),
    );
  }
}

class _DriveTableHeader extends StatelessWidget {
  const _DriveTableHeader();

  @override
  Widget build(BuildContext context) {
    final narrow = _isDriveNarrow(context);
    return Padding(
      padding: EdgeInsets.only(
          bottom: 8,
          left: narrow ? _driveNarrowRowInset : 16,
          right: narrow ? _driveNarrowRowInset : 16),
      child: Row(
        children: [
          Expanded(
              flex: 5,
              child: Text(narrow ? '名称 / 修改日期' : '名称',
                  style: narrow
                      ? _headerStyle.copyWith(
                          fontSize: 12, fontWeight: FontWeight.w400)
                      : _headerStyle)),
          if (!narrow)
            const Expanded(flex: 2, child: Text('修改日期', style: _headerStyle)),
          SizedBox(
              width: 48,
              child: Text('操作',
                  style: narrow
                      ? _headerStyle.copyWith(
                          fontSize: 12, fontWeight: FontWeight.w400)
                      : _headerStyle)),
        ],
      ),
    );
  }
}

class _SharedDriveRootList extends StatelessWidget {
  const _SharedDriveRootList({required this.spaces});

  final List<DriveSpace> spaces;

  @override
  Widget build(BuildContext context) {
    final filter = DriveBrowseFilter.maybeOf(context);
    final visible = spaces
        .where((space) => filter?.matchesFolder(space.displayName) ?? true)
        .toList();
    if (visible.isEmpty) {
      return _EmptyState(message: spaces.isEmpty ? '暂无共享文件夹' : '没有匹配的共享文件夹');
    }
    final isNarrow = _isDriveNarrow(context);
    return ListView.separated(
      padding:
          EdgeInsets.fromLTRB(isNarrow ? 16 : 32, 12, isNarrow ? 16 : 32, 32),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _SharedFolderCard(space: visible[i]),
    );
  }
}

class _SharedFolderCard extends ConsumerStatefulWidget {
  const _SharedFolderCard({required this.space});

  final DriveSpace space;

  @override
  ConsumerState<_SharedFolderCard> createState() => _SharedFolderCardState();
}

class _SharedFolderCardState extends ConsumerState<_SharedFolderCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final rootFolders =
        ref.read(driveTreeProvider.notifier).rootFoldersOf(widget.space.uuid);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          openDriveSelection(
            context,
            ref,
            selection: const DriveSelection(kind: DriveSelectionKind.driveRoot),
            space: widget.space.uuid,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFEEF3FF) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  _hovered ? const Color(0xFFB8CEFF) : const Color(0xFFEEEEEE),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_shared_outlined,
                  size: 22, color: Color(0xFF8C8C8C)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.space.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              Text('${rootFolders.length} 个目录',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
            ],
          ),
        ),
      ),
    );
  }
}

class _KbListCard extends ConsumerStatefulWidget {
  const _KbListCard({required this.kb, required this.scope});

  final KbItem kb;
  final String scope;

  @override
  ConsumerState<_KbListCard> createState() => _KbListCardState();
}

class _KbListCardState extends ConsumerState<_KbListCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openDriveSelection(
          context,
          ref,
          selection: DriveSelection(
            kind: DriveSelectionKind.kb,
            kbUuid: widget.kb.uuid,
          ),
          space: widget.scope,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFF6F1FF) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  _hovered ? const Color(0xFFD6C4FF) : const Color(0xFFEEEEEE),
            ),
          ),
          child: Row(
            children: [
              const Icon(CupertinoIcons.book_fill,
                  size: 22, color: Color(0xFF722ED1)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.kb.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              Text(widget.kb.totalDocumentsLabel,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面包屑 + 标题 + 工具栏
class _Header extends ConsumerWidget {
  const _Header({
    required this.folder,
    required this.compact,
    required this.space,
  });

  final DriveFolder folder;
  final bool compact;
  final String space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(driveTreeProvider.notifier);
    final tree = ref.watch(driveTreeProvider).value;

    // 计算面包屑链
    final breadcrumb = <DriveFolder>[folder];
    var cur = folder;
    while (cur.parentId.isNotEmpty) {
      final p = notifier.findFolder(cur.parentId);
      if (p == null) break;
      breadcrumb.insert(0, p);
      cur = p;
    }

    final canUpload = !folder.isSystem && folder.isRegular;
    final canCreateChild = canUpload;
    final isNarrow = _isDriveNarrow(context);
    final hPad = isNarrow ? 16.0 : 32.0;
    final breadcrumbLabels = _driveFolderBreadcrumbCrumbs(
      context,
      ref,
      tree,
      space,
      breadcrumb,
    );

    final mobileFilter = DriveBrowseFilter.maybeOf(context);
    if (mobileFilter != null) {
      final create = _DriveCreateMenuButton(
        enabled: canCreateChild,
        onCreateFolder: () => _showNewFolderDialog(context, ref, folder),
        onCreateDoc: () => showDriveToast('新建文档功能 M3 上线', error: false),
      );
      final importButton = _DriveImportMenuButton(
        enabled: canUpload,
        onImportLocal: () => _pickAndUpload(context, ref, folder),
        onImportFromChat: () => _importFromChatFlow(context, ref, folder),
      );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (mobileFilter.breadcrumbs != null)
          _DriveMobileToolbar(
              breadcrumbs: mobileFilter.breadcrumbs!,
              create: create,
              importButton: importButton)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(children: [
              if (compact)
                const Spacer()
              else
                Expanded(
                    child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                      children: _driveBreadcrumbWidgets(breadcrumbLabels,
                          compact: true,),
                ),
                      ),
                    ),
              create,
              importButton,
            ]),
          ),
        if (folder.isSystem)
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _SystemFolderTip()),
      ]);
    }
    return Container(
      padding: EdgeInsets.fromLTRB(hPad, isNarrow ? 14 : 24, hPad, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isNarrow) ...[
            if (!compact) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _driveBreadcrumbWidgets(breadcrumbLabels,
                      compact: isNarrow),
                ),
              ),
              const SizedBox(height: 10),
              if (folder.isSystem) const _SystemFolderTip(),
              SizedBox(height: folder.isSystem ? 12 : 0),
            ],
            Row(
              children: [
                Expanded(
                  child: _DriveCreateMenuButton(
                    enabled: canCreateChild,
                    onCreateFolder: () {
                      ref.read(selectedSpaceProvider.notifier).state = space;
                      _showNewFolderDialog(context, ref, folder);
                    },
                    onCreateDoc: () =>
                        showDriveToast('新建文档功能 M3 上线', error: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DriveImportMenuButton(
                    enabled: canUpload,
                    onImportLocal: () {
                      ref.read(selectedSpaceProvider.notifier).state = space;
                      _pickAndUpload(context, ref, folder);
                    },
                    onImportLocalFolder: PlatformUtils.isMobile
                        ? null
                        : () {
                            ref.read(selectedSpaceProvider.notifier).state =
                                space;
                            _pickAndUploadFolder(context, ref, folder);
                          },
                    onImportFromChat: () =>
                        _importFromChatFlow(context, ref, folder),
                  ),
                ),
              ],
            ),
            if (compact && folder.isSystem) const _SystemFolderTip(),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _driveBreadcrumbWidgets(breadcrumbLabels,
                          compact: isNarrow),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // + 新建 下拉(对齐设计文档 §6.2.C)
                _DriveCreateMenuButton(
                  enabled: canCreateChild,
                  onCreateFolder: () {
                    ref.read(selectedSpaceProvider.notifier).state = space;
                    _showNewFolderDialog(context, ref, folder);
                  },
                  onCreateDoc: () =>
                      showDriveToast('新建文档功能 M3 上线', error: false),
                ),
                const SizedBox(width: 8),
                // ↑ 导入 下拉(对齐设计稿:文件 / 文件夹 / 聊天)
                _DriveImportMenuButton(
                  enabled: canUpload,
                  onImportLocal: () {
                    ref.read(selectedSpaceProvider.notifier).state = space;
                    _pickAndUpload(context, ref, folder);
                  },
                  onImportLocalFolder: PlatformUtils.isMobile
                      ? null
                      : () {
                          ref.read(selectedSpaceProvider.notifier).state =
                              space;
                          _pickAndUploadFolder(context, ref, folder);
                        },
                  onImportFromChat: () =>
                      _importFromChatFlow(context, ref, folder),
                ),
              ],
            ),
            if (folder.isSystem) const _SystemFolderTip(),
          ],
        ],
      ),
    );
  }
}

List<String> _driveFolderBreadcrumbLabels(
  DriveTreeState? tree,
  String spaceUuid,
  List<DriveFolder> folders,
) {
  final personalUuid = tree?.personal?.uuid ?? '';
  if (spaceUuid == personalUuid) {
    return ['我的空间', '云盘', ...folders.map((f) => f.name)];
  }
  for (final sp in tree?.orgSpaces ?? const <DriveSpace>[]) {
    if (sp.uuid == spaceUuid) {
      return ['共享空间', '云盘', sp.displayName, ...folders.map((f) => f.name)];
    }
  }
  return ['云盘', ...folders.map((f) => f.name)];
}

/// 前缀段(我的空间/共享空间/云盘/空间名)统一跳回该 space 的云盘根；
/// 目录段逐级可跳，最后一段(当前目录)不可点。
List<_DriveCrumb> _driveFolderBreadcrumbCrumbs(
  BuildContext context,
  WidgetRef ref,
  DriveTreeState? tree,
  String spaceUuid,
  List<DriveFolder> folders,
) {
  final labels = _driveFolderBreadcrumbLabels(tree, spaceUuid, folders);
  final prefixCount = labels.length - folders.length;
  void toRoot() => openDriveSelection(
        context,
        ref,
        selection: const DriveSelection(kind: DriveSelectionKind.driveRoot),
        space: spaceUuid,
      );
  return [
    for (var i = 0; i < labels.length; i++)
      if (i < prefixCount)
        _DriveCrumb(labels[i], toRoot)
      else
        _DriveCrumb(
          labels[i],
          i == labels.length - 1
              ? null
              : () => openDriveSelection(
                    context,
                    ref,
                    selection: DriveSelection(
                      kind: DriveSelectionKind.driveFolder,
                      folderUuid: folders[i - prefixCount].uuid,
                    ),
                    space: spaceUuid,
                  ),
        ),
  ];
}

class _SystemFolderTip extends StatelessWidget {
  const _SystemFolderTip();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Text(
        '系统目录(由数字员工自动创建,不可修改)',
        style: TextStyle(fontSize: 12, color: Color(0xFFFA8C16)),
      ),
    );
  }
}

class DriveFolderActionMenu extends ConsumerWidget {
  const DriveFolderActionMenu({
    super.key,
    required this.folder,
    required this.parentUuid,
  });

  final DriveFolder folder;
  final String parentUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return UiDropdownMenu<String>(
      menuWidth: 150,
      hoverRadius: 8,
      items: const [
        UiDropdownMenuItem(
            value: 'rename', label: '重命名', icon: CupertinoIcons.pencil),
        UiDropdownMenuItem(
            value: 'move',
            label: '移动到…',
            icon: CupertinoIcons.arrow_right_arrow_left),
        UiDropdownMenuItem(
            value: 'delete',
            label: '删除',
            icon: CupertinoIcons.delete,
            danger: true),
      ],
      onSelected: (action) async {
        switch (action) {
          case 'rename':
            await _renameFolderDialog(context, ref, folder, parentUuid);
          case 'move':
            await _moveFolderDialog(context, ref, folder, parentUuid);
          case 'delete':
            await _confirmDeleteFolder(context, ref, folder, parentUuid);
        }
      },
      child: const SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          CupertinoIcons.ellipsis,
          size: 18,
          color: Color(0xFF595959),
        ),
      ),
    );
  }
}

class _ChildrenList extends ConsumerStatefulWidget {
  const _ChildrenList({
    required this.folder,
    required this.state,
    required this.space,
  });

  final DriveFolder folder;
  final DriveContentState state;
  final String space;

  @override
  ConsumerState<_ChildrenList> createState() => _ChildrenListState();
}

class _ChildrenListState extends ConsumerState<_ChildrenList> {
  // 滚到接近底部时拉下一页；ScrollController 必须随 State 释放（不能在 build 里 new）。
  final ScrollController _scrollController = ScrollController();
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      _maybeLoadMore();
    }
  }

  Future<void> _maybeLoadMore() async {
    if (_loadingMore || !widget.state.hasMore) return;
    setState(() => _loadingMore = true);
    try {
      await ref
          .read(driveContentProvider(widget.folder.uuid).notifier)
          .loadMore();
    } catch (e) {
      if (!isTransientNetworkError(e)) {
        showDriveToast('加载更多失败:$e', error: true);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.state.children;
    final isNarrow = _isDriveNarrow(context);
    if (children == null) return const SizedBox.shrink();

    if (children.folders.isEmpty &&
        children.files.isEmpty &&
        !widget.state.hasMore) {
      return const _EmptyState(message: '该目录还没有内容');
    }

    final filter = DriveBrowseFilter.maybeOf(context);
    final folders = children.folders
        .where((folder) => filter?.matchesFolder(folder.name) ?? true)
        .toList();
    final files = children.files
        .where((file) => filter?.matchesFile(file) ?? true)
        .toList();
    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        isNarrow ? _driveNarrowContentInset - _driveNarrowRowInset : 32,
        isNarrow ? 0 : 8,
        isNarrow ? _driveNarrowContentInset - _driveNarrowRowInset : 32,
        32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 列头
          const _DriveTableHeader(),
          if (folders.isEmpty && files.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('已加载内容中没有匹配的文件'))),
          ...folders.map((sub) => _SubFolderRow(
                folder: sub,
                parentUuid: widget.folder.uuid,
                space: widget.space,
              )),
          ...files.map((f) => _FileRow(
                file: f,
                location: _DriveLocation.folder(parent: widget.folder),
              )),
          if (widget.state.hasMore && !_loadingMore)
            TextButton(onPressed: _maybeLoadMore, child: const Text('继续加载')),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CupertinoActivityIndicator(radius: 10)),
            ),
        ],
      ),
    );
  }
}

const _headerStyle = _driveListHeaderStyle;

class _DriveLocation {
  const _DriveLocation._({
    required this.spaceUuid,
    this.parent
  });

  factory _DriveLocation.root({required String spaceUuid}) =>
      _DriveLocation._(spaceUuid: spaceUuid);

  factory _DriveLocation.folder({required DriveFolder parent}) =>
      _DriveLocation._(spaceUuid: '', parent: parent);

  final String spaceUuid;
  final DriveFolder? parent;

  bool get isRoot => parent == null;
  String get parentUuid => parent?.uuid ?? '';
}

class _SubFolderRow extends ConsumerStatefulWidget {
  const _SubFolderRow({
    required this.folder,
    required this.parentUuid,
    required this.space,
  });

  final DriveFolder folder;
  final String parentUuid;
  final String space;

  @override
  ConsumerState<_SubFolderRow> createState() => _SubFolderRowState();
}

class _SubFolderRowState extends ConsumerState<_SubFolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final folder = widget.folder;
    final isNarrow = _isDriveNarrow(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: UiTapSurface(
        onHover: (value) => setState(() => _hovered = value),
        onTap: () => openDriveSelection(
          context,
          ref,
          selection: DriveSelection(
            kind: DriveSelectionKind.driveFolder,
            folderUuid: folder.uuid,
          ),
          space: widget.space,
        ),
        color: Theme.of(context).colorScheme.surface,
        borderSide: isNarrow
            ? BorderSide.none
            : BorderSide(
                color: _hovered
                    ? const Color(0xFFB8CEFF)
                    : const Color(0xFFEEEEEE),
              ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? _driveNarrowRowInset : 16,
            vertical: isNarrow ? 8 : 12,
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF1E0),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        CupertinoIcons.folder_fill,
                        color: Color(0xFFFA8C16),
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            folder.name,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (folder.isSystem)
                            const Text(
                              '系统目录',
                              style: TextStyle(
                                  fontSize: 11, color: Color(0xFFFA8C16)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!isNarrow) const Expanded(flex: 2, child: SizedBox()),
              SizedBox(
                width: 48,
                child: folder.isSystem
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: UiDropdownMenu<String>(
                          menuWidth: 150,
                          hoverRadius: 8,
                          items: const [
                            UiDropdownMenuItem(
                                value: 'rename',
                                label: '重命名',
                                icon: CupertinoIcons.pencil),
                            UiDropdownMenuItem(
                                value: 'move',
                                label: '移动到…',
                                icon: CupertinoIcons.arrow_right_arrow_left),
                            UiDropdownMenuItem(
                                value: 'delete',
                                label: '删除',
                                icon: CupertinoIcons.delete,
                                danger: true),
                          ],
                          onSelected: (action) async {
                            switch (action) {
                              case 'rename':
                                await _renameFolderDialog(
                                    context, ref, folder, widget.parentUuid);
                              case 'move':
                                await _moveFolderDialog(
                                    context, ref, folder, widget.parentUuid);
                              case 'delete':
                                await _confirmDeleteFolder(
                                    context, ref, folder, widget.parentUuid);
                            }
                          },
                          child: const SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(CupertinoIcons.ellipsis,
                                size: 16, color: Color(0xFF8C8C8C)),
                          ),
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

class _FileRow extends ConsumerStatefulWidget {
  const _FileRow({required this.file, required this.location});
  final DriveFile file;
  final _DriveLocation location;

  @override
  ConsumerState<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends ConsumerState<_FileRow> {
  bool _hovered = false;

  Widget _leadingIcon(DriveFile file) => DriveFileIcon(
        mimeType: file.mimeType,
        name: file.name,
        fileUuid: file.uuid,
      );

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final location = widget.location;
    final isNarrow = _isDriveNarrow(context);
    final isFavorite = _isResourceFavorite(
      ref.watch(driveFavoritesProvider).value,
      targetKind: 'drive_file',
      targetUuid: file.uuid,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: UiTapSurface(
        onHover: (value) => setState(() => _hovered = value),
        onTap: () => previewDriveFile(context, ref, file),
        color: Theme.of(context).colorScheme.surface,
        borderSide: isNarrow
            ? BorderSide.none
            : BorderSide(
                color: _hovered
                    ? const Color(0xFFB8CEFF)
                    : const Color(0xFFEEEEEE),
              ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? _driveNarrowRowInset : 16,
            vertical: isNarrow ? 8 : 12,
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _leadingIcon(file),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file.name,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isNarrow
                                ? '${file.sizeDisplay} · ${_formatDate(file.updatedAt)}'
                                : file.sizeDisplay,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF8C8C8C)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!isNarrow)
                Expanded(
                  flex: 2,
                  child: Text(
                    _formatDate(file.updatedAt),
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFF595959)),
                  ),
                ),
              SizedBox(
                width: 48,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: UiDropdownMenu<String>(
                    menuWidth: 160,
                    hoverRadius: 8,
                    items: [
                      const UiDropdownMenuItem(
                          value: 'download',
                          label: '下载',
                          icon: CupertinoIcons.cloud_download),
                      UiDropdownMenuItem(
                          value: 'favorite',
                          label: isFavorite ? '取消收藏' : '收藏',
                          icon: isFavorite
                              ? CupertinoIcons.star_fill
                              : CupertinoIcons.star),
                      const UiDropdownMenuItem(
                          value: 'rename',
                          label: '重命名',
                          icon: CupertinoIcons.pencil),
                      const UiDropdownMenuItem(
                          value: 'move',
                          label: '移动到…',
                          icon: CupertinoIcons.arrow_right_arrow_left),
                      const UiDropdownMenuItem(
                          value: 'addToKb',
                          label: '加入知识库…',
                          icon: CupertinoIcons.book),
                      const UiDropdownMenuItem(
                          value: 'delete',
                          label: '删除',
                          icon: CupertinoIcons.delete,
                          danger: true),
                    ],
                    onSelected: (action) async {
                      switch (action) {
                        case 'download':
                          await _downloadFile(context, ref, file);
                        case 'favorite':
                          await _toggleFavorite(
                            ref,
                            targetKind: 'drive_file',
                            targetUuid: file.uuid,
                            isFavorite: isFavorite,
                          );
                        case 'rename':
                          await _renameFileDialog(context, ref, file, location);
                        case 'move':
                          await _moveFileDialog(context, ref, file, location);
                        case 'addToKb':
                          await _addToKb(context, ref, file);
                        case 'delete':
                          await _confirmDeleteFile(
                              context, ref, file, location);
                      }
                    },
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(CupertinoIcons.ellipsis,
                          size: 16, color: Color(0xFF8C8C8C)),
                    ),
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

String _formatDate(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  final local = dt.toLocal();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

bool _isResourceFavorite(
  List<DriveFavoriteItem>? favorites, {
  required String targetKind,
  required String targetUuid,
}) {
  if (favorites == null) return false;
  return favorites.any(
    (item) => item.targetKind == targetKind && item.targetUuid == targetUuid,
  );
}

Future<void> _toggleFavorite(
  WidgetRef ref, {
  required String targetKind,
  required String targetUuid,
  required bool isFavorite,
  String kbUuid = '',
}) async {
  try {
    final service = ref.read(driveServiceProvider);
    if (isFavorite) {
      await service.removeFavorite(
        targetKind: targetKind,
        targetUuid: targetUuid,
      );
    } else {
      await service.addFavorite(
        targetKind: targetKind,
        targetUuid: targetUuid,
        kbUuid: kbUuid,
      );
    }
    ref.invalidate(driveFavoritesProvider);
    showDriveToast(isFavorite ? '已取消收藏' : '已收藏');
  } catch (e) {
    showDriveToast(isFavorite ? '取消收藏失败:$e' : '收藏失败:$e', error: true);
  }
}

// ===== 操作 =====

Future<void> _showNewRootFolderDialog(
  BuildContext context,
  WidgetRef ref, {
  required String spaceUuid,
  required String spaceLabel,
}) async {
  final result = await showUiInputDialog(
    context,
    title: '在「$spaceLabel」下新建目录',
    hintText: '目录名称',
    confirmLabel: '创建',
  );
  if (result == null || result.isEmpty) return;
  try {
    await ref.read(driveServiceProvider).createFolder(
          spaceUuid: spaceUuid,
          name: result,
          parentUuid: ''
        );
    await ref.read(driveTreeProvider.notifier).reloadSpace(spaceUuid);
    showDriveToast('创建成功');
  } catch (e) {
    showDriveToast('创建失败:$e', error: true);
  }
}

Future<void> _showCreateSharedFolderDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final result = await showDialog<_CreateSharedFolderResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => const _CreateSharedFolderDialog(),
  );
  if (result == null || result.name.isEmpty) return;
  try {
    final svc = ref.read(driveServiceProvider);
    final space = await svc.createSharedSpace(
      name: result.name,
      description: result.description,
    );
    int invited = 0;
    int failed = 0;
    for (final p in result.collaborators) {
      try {
        await svc.addSpaceMember(
          spaceUuid: space.uuid,
          accountUuid: p.id,
          role: 'editor',
        );
        invited += 1;
      } catch (_) {
        failed += 1;
      }
    }
    ref.invalidate(driveTreeProvider);
    if (failed > 0) {
      showDriveToast('创建成功,$invited 个协作者已添加,$failed 个添加失败', error: true);
    } else {
      showDriveToast(invited > 0 ? '创建成功,已添加 $invited 个协作者' : '创建成功');
    }
  } catch (e) {
    showDriveToast('创建失败:$e', error: true);
  }
}

class _CreateSharedFolderResult {
  const _CreateSharedFolderResult({
    required this.name,
    required this.description,
    required this.collaborators,
  });

  final String name;
  final String description;
  final List<ContactPerson> collaborators;
}

class _CreateSharedFolderDialog extends StatefulWidget {
  const _CreateSharedFolderDialog();

  @override
  State<_CreateSharedFolderDialog> createState() =>
      _CreateSharedFolderDialogState();
}

class _CreateSharedFolderDialogState extends State<_CreateSharedFolderDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final List<ContactPerson> _collaborators = [];

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickCollaborators() async {
    final picked = await showDriveCollaboratorPicker(
      context,
      initialSelected: _collaborators,
    );
    if (picked == null) return;
    setState(() {
      _collaborators
        ..clear()
        ..addAll(picked);
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_CreateSharedFolderResult(
      name: name,
      description: _descriptionController.text.trim(),
      collaborators: List.unmodifiable(_collaborators),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _nameController.text.trim().isNotEmpty;
    return UiContentDialog(
      child: SingleChildScrollView(
        child: Padding(
          padding: PlatformUtils.isMobile
              ? const EdgeInsets.all(20)
              : const EdgeInsets.fromLTRB(28, 24, 28, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(
                title: '新建共享文件夹',
                subtitle: '共享空间 / 云盘',
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 18),
              const _DialogFieldLabel('名称'),
              UiInputField(
                controller: _nameController,
                autofocus: true,
                hintText: '请输入名称',
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              const _DialogFieldLabel('描述'),
              UiInputField(
                controller: _descriptionController,
                maxLength: 512,
                hintText: '请输入描述',
              ),
              const SizedBox(height: 16),
              const _DialogFieldLabel('邀请协作者'),
              DriveCollaboratorInputRow(
                collaborators: _collaborators,
                onPick: _pickCollaborators,
                onRemove: (id) => setState(
                  () => _collaborators.removeWhere((p) => p.id == id),
                ),
              ),
              const SizedBox(height: 22),
              if (PlatformUtils.isMobile)
                UiFormActions(
                  primaryLabel: '创建',
                  onPrimary: canSubmit ? _submit : null,
                  secondaryLabel: '取消',
                  onSecondary: () => Navigator.of(context).pop(),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: canSubmit ? _submit : null,
                      child: const Text('创建'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogFieldLabel extends StatelessWidget {
  const _DialogFieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Color(0xFF595959),
        ),
      ),
    );
  }
}

Future<void> _showNewFolderDialog(
    BuildContext context, WidgetRef ref, DriveFolder parent) async {
  final result = await showUiInputDialog(
    context,
    title: '在「${parent.name}」下新建目录',
    hintText: '目录名称',
    confirmLabel: '创建',
  );
  if (result == null || result.isEmpty) return;
  try {
    final space = _spaceUuidOf(ref, parent);
    await ref.read(driveServiceProvider).createFolder(
          spaceUuid: space,
          name: result,
          parentUuid: parent.uuid
        );
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    ref.invalidate(driveContentProvider(parent.uuid));
    showDriveToast('创建成功');
  } catch (e) {
    showDriveToast('创建失败:$e', error: true);
  }
}

/// 解析某 folder 所属的真实 space uuid(上传 presign 必需)。树里找不到时退回当前选中 space。
String _spaceUuidOf(WidgetRef ref, DriveFolder folder) {
  final u = ref.read(driveTreeProvider.notifier).spaceUuidOfFolder(folder.uuid);
  return u.isNotEmpty ? u : ref.read(selectedSpaceProvider);
}

Future<void> _pickAndUpload(
    BuildContext context, WidgetRef ref, DriveFolder folder) async {
  final selected = await openFiles(); // 多选
  if (selected.isEmpty) return;
  final svc = ref.read(driveServiceProvider);
  final spaceUuid = _spaceUuidOf(ref, folder);
  int success = 0;
  int fail = 0;
  final cancel = BotToast.showLoading();
  try {
    for (final xfile in selected) {
      try {
        await svc.uploadFile(
          spaceUuid: spaceUuid,
          folderUuid: folder.uuid,
          filePath: xfile.path,
          fileName: xfile.name,
        );
        success += 1;
      } catch (e) {
        fail += 1;
        showDriveToast('${xfile.name} 上传失败:$e', error: true);
      }
    }
  } finally {
    cancel();
  }
  ref.invalidate(driveContentProvider(folder.uuid));
  showDriveToast(fail == 0 ? '已上传 $success 个文件' : '上传 $success 成功 / $fail 失败',
      error: fail > 0);
}

Future<void> _pickAndUploadToSpaceRoot(
  BuildContext context,
  WidgetRef ref, {
  required String spaceUuid,
}) async {
  final selected = await openFiles();
  if (selected.isEmpty) return;
  final svc = ref.read(driveServiceProvider);
  int success = 0;
  int fail = 0;
  final cancel = BotToast.showLoading();
  try {
    for (final xfile in selected) {
      try {
        await svc.uploadFile(
          spaceUuid: spaceUuid,
          filePath: xfile.path,
          fileName: xfile.name,
        );
        success += 1;
      } catch (e) {
        fail += 1;
        showDriveToast('${xfile.name} 上传失败:$e', error: true);
      }
    }
  } finally {
    cancel();
  }
  ref.invalidate(driveRootFilesProvider(spaceUuid));
  ref.invalidate(driveRecentFilesProvider);
  showDriveToast(fail == 0 ? '已上传 $success 个文件' : '上传 $success 成功 / $fail 失败',
      error: fail > 0);
}

Future<void> _pickAndUploadFolderToSpaceRoot(
  BuildContext context,
  WidgetRef ref, {
  required String spaceUuid,
}) async {
  final dirPath = await getDirectoryPath();
  if (dirPath == null) return;
  final root = Directory(dirPath);
  if (!await root.exists()) return;
  final rootName = root.uri.pathSegments.where((s) => s.isNotEmpty).last;

  try {
    final created = await ref.read(driveServiceProvider).createFolder(
          spaceUuid: spaceUuid,
          name: rootName,
          parentUuid: ''
        );
    await ref.read(driveTreeProvider.notifier).reloadSpace(spaceUuid);
    await _pickAndUploadFolderContents(
      ref,
      dirPath: dirPath,
      targetFolder: created,
      spaceUuid: spaceUuid,
    );
  } catch (e) {
    showDriveToast('导入文件夹失败:$e', error: true);
  }
}

Future<void> _pickAndUploadFolder(
    BuildContext context, WidgetRef ref, DriveFolder targetFolder) async {
  final dirPath = await getDirectoryPath();
  if (dirPath == null) return;
  final space = _spaceUuidOf(ref, targetFolder);
  await _pickAndUploadFolderContents(
    ref,
    dirPath: dirPath,
    targetFolder: targetFolder,
    spaceUuid: space,
  );
}

Future<void> _pickAndUploadFolderContents(
  WidgetRef ref, {
  required String dirPath,
  required DriveFolder targetFolder,
  required String spaceUuid,
}) async {
  final root = Directory(dirPath);
  if (!await root.exists()) return;

  final svc = ref.read(driveServiceProvider);

  // 收集所有 entity,先排序保证父目录先于子目录处理
  final entities = await root.list(recursive: true).toList();
  entities.sort((a, b) => a.path.length.compareTo(b.path.length));

  // localRelDir → cloud folder uuid;空 key 代表根(=> targetFolder.uuid)
  final folderMap = <String, String>{'': targetFolder.uuid};
  int fileSuccess = 0;
  int fileFail = 0;

  String relFrom(String absPath) {
    var rel = absPath;
    if (rel.startsWith(dirPath)) {
      rel = rel.substring(dirPath.length);
    }
    rel = rel.replaceAll('\\', '/'); // Windows 兜底
    if (rel.startsWith('/')) rel = rel.substring(1);
    return rel;
  }

  String parentRelOf(String rel) {
    final i = rel.lastIndexOf('/');
    return i < 0 ? '' : rel.substring(0, i);
  }

  String baseNameOf(String rel) {
    final i = rel.lastIndexOf('/');
    return i < 0 ? rel : rel.substring(i + 1);
  }

  final cancel = BotToast.showLoading();
  try {
    // 第一遍:建所有子目录
    for (final e in entities) {
      if (e is! Directory) continue;
      final rel = relFrom(e.path);
      if (rel.isEmpty) continue; // 跳过根
      final parentRel = parentRelOf(rel);
      final parentUuid = folderMap[parentRel] ?? targetFolder.uuid;
      try {
        final created = await svc.createFolder(
          spaceUuid: spaceUuid,
          name: baseNameOf(rel),
          parentUuid: parentUuid,
        );
        folderMap[rel] = created.uuid;
      } catch (err) {
        // 建失败的话,该目录下的文件就传到最近的已建父目录里(降级,不丢文件)
        folderMap[rel] = parentUuid;
      }
    }
    // 第二遍:上传所有文件到对应目录
    for (final e in entities) {
      if (e is! File) continue;
      final rel = relFrom(e.path);
      final parentRel = parentRelOf(rel);
      final parentUuid = folderMap[parentRel] ?? targetFolder.uuid;
      try {
        await svc.uploadFile(
          spaceUuid: spaceUuid,
          folderUuid: parentUuid,
          filePath: e.path,
          fileName: baseNameOf(rel),
        );
        fileSuccess += 1;
      } catch (err) {
        fileFail += 1;
      }
    }
  } finally {
    cancel();
  }

  await ref.read(driveTreeProvider.notifier).reloadSpace(spaceUuid);
  ref.invalidate(driveContentProvider(targetFolder.uuid));
  showDriveToast(
      fileFail == 0
          ? '已导入文件夹「${root.uri.pathSegments.where((s) => s.isNotEmpty).last}」($fileSuccess 个文件)'
          : '导入完成:$fileSuccess 成功 / $fileFail 失败',
      error: fileFail > 0);
}

Future<void> _uploadDroppedFiles(
    WidgetRef ref, DriveFolder folder, List<XFile> files) async {
  if (files.isEmpty) return;
  if (folder.isSystem || !folder.isRegular) {
    showDriveToast('该目录不允许上传', error: true);
    return;
  }
  final svc = ref.read(driveServiceProvider);
  final spaceUuid = _spaceUuidOf(ref, folder);
  int success = 0;
  int fail = 0;
  final cancel = BotToast.showLoading();
  try {
    for (final f in files) {
      try {
        await svc.uploadFile(
          spaceUuid: spaceUuid,
          folderUuid: folder.uuid,
          filePath: f.path,
          fileName: f.name,
        );
        success += 1;
      } catch (e) {
        fail += 1;
        showDriveToast('${f.name} 拖拽上传失败:$e', error: true);
      }
    }
  } finally {
    cancel();
  }
  ref.invalidate(driveContentProvider(folder.uuid));
  showDriveToast(fail == 0 ? '已拖拽上传 $success 个文件' : '上传 $success 成功 / $fail 失败',
      error: fail > 0);
}

Future<void> previewDriveFavorite(
    BuildContext context, WidgetRef ref, DriveFavoriteItem item) async {
  if (item.isDriveFile) {
    await previewDriveFile(
        context,
        ref,
        DriveFile(
            uuid: item.targetUuid,
            name: item.name,
            mimeType: item.mimeType,
            sizeBytes: item.sizeBytes,
            source: 'favorite',
            spaceUuid: item.spaceUuid,
            driveFolderUuid: item.folderUuid,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt));
  } else if (item.isKbDocument) {
    await _downloadKbDoc(
        context,
        ref,
        KbDocument(
            uuid: item.targetUuid,
            kbUuid: item.kbUuid,
            fileUuid: '',
            fileName: item.name,
            kbFolderUuid: item.folderUuid,
            mimeType: item.mimeType,
            sizeBytes: item.sizeBytes,
            source: 'kb_upload',
            status: item.status,
            chunksCount: 0,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt));
  }
}

Future<void> previewDriveFile(
    BuildContext context, WidgetRef ref, DriveFile file) async {
  try {
    final url =
        await ref.read(driveServiceProvider).previewUrl(fileUuid: file.uuid);
    // 图片类直接弹应用内大图预览(沿用 ui_image_preview 的统一预览组件),
    // 不再跳浏览器。S3 presigned URL 自带签名,无需 headers。
    if (file.mimeType.startsWith('image/')) {
      if (!context.mounted) return;
      showImagePreviewRoute<void>(
        context: context,
        useSafeArea: Theme.of(context).platform != TargetPlatform.iOS &&
            Theme.of(context).platform != TargetPlatform.android,
        builder: (_) =>
            UiImagePreviewDialog(fileUrl: url.url, cacheKey: file.uuid),
      );
      return;
    }
    final uri = Uri.parse(url.url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      showDriveToast('预览打开失败', error: true);
    }
  } catch (e) {
    showDriveToast('预览失败:$e', error: true);
  }
}

Future<void> _downloadFile(
    BuildContext context, WidgetRef ref, DriveFile file) async {
  try {
    final url = await ref.read(driveServiceProvider).previewUrl(
          fileUuid: file.uuid,
          download: true
        );
    final uri = Uri.parse(url.url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      showDriveToast('下载失败', error: true);
    }
  } catch (e) {
    showDriveToast('下载失败:$e', error: true);
  }
}

void _refreshFileLocation(WidgetRef ref, _DriveLocation location) {
  if (location.isRoot) {
    ref.invalidate(driveRootFilesProvider(location.spaceUuid));
  } else {
    ref.invalidate(driveContentProvider(location.parentUuid));
  }
  ref.invalidate(driveRecentFilesProvider);
}

Future<void> _confirmDeleteFile(BuildContext context, WidgetRef ref,
    DriveFile file, _DriveLocation location) async {
  final ok = await showUiConfirmDialog(
    context,
    title: '删除文件',
    description: '确定删除「${file.name}」吗?',
    confirmLabel: '删除',
    danger: true,
  );
  if (!ok) return;
  try {
    await ref.read(driveServiceProvider).deleteFile(file.uuid);
    _refreshFileLocation(ref, location);
    showDriveToast('已删除');
  } catch (e) {
    showDriveToast('删除失败:$e', error: true);
  }
}

Future<void> _confirmDeleteFolder(BuildContext context, WidgetRef ref,
    DriveFolder folder, String parentUuid) async {
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
    final space = ref.read(selectedSpaceProvider);
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    if (parentUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(parentUuid));
    }
    // 如果当前选中的就是被删的目录,清掉 selection 防止右侧仍渲染僵尸目录
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
//  文件 / 文件夹 操作(rename / move / addToKb)
// ============================================================

Future<void> _renameFileDialog(BuildContext context, WidgetRef ref,
    DriveFile file, _DriveLocation location) async {
  final result = await showUiInputDialog(
    context,
    title: '重命名文件',
    initialValue: file.name,
  );
  if (result == null || result.isEmpty || result == file.name) return;
  try {
    await ref
        .read(driveServiceProvider)
        .renameFile(fileUuid: file.uuid, name: result);
    _refreshFileLocation(ref, location);
    showDriveToast('已重命名');
  } catch (e) {
    showDriveToast('重命名失败:$e', error: true);
  }
}

Future<void> _moveFileDialog(BuildContext context, WidgetRef ref,
    DriveFile file, _DriveLocation location) async {
  final targetUuid = await showFolderPickerDialog(
    context,
    ref,
    title: '选择目标目录',
    excludeUuids: [if (location.parentUuid.isNotEmpty) location.parentUuid],
  );
  if (targetUuid == null || targetUuid == location.parentUuid) {
    return;
  }
  try {
    await ref
        .read(driveServiceProvider)
        .moveFile(fileUuid: file.uuid, newFolderUuid: targetUuid);
    _refreshFileLocation(ref, location);
    ref.invalidate(driveContentProvider(targetUuid));
    showDriveToast('已移动');
  } catch (e) {
    showDriveToast('移动失败:$e', error: true);
  }
}

Future<void> _addToKb(
    BuildContext context, WidgetRef ref, DriveFile file) async {
  if (!_isKnowledgeSupportedDriveFile(file)) {
    showDriveToast(knowledgeDocumentFormatHint, error: true);
    return;
  }
  final kbUuid = await showKbPickerDialog(
    context,
    ref,
    writableOnly: true
  );
  if (kbUuid == null) return;
  try {
    await ref.read(knowledgeServiceProvider).linkFromDrive(
      kbUuid: kbUuid,
      fileUuids: [file.uuid]
    );
    ref.invalidate(knowledgeDocumentsProvider(
      KnowledgeDocumentsQuery(kbUuid: kbUuid)),
    );
    showDriveToast('已加入知识库');
  } catch (e) {
    showDriveToast('加入知识库失败:${_knowledgeOperationError(e)}', error: true);
  }
}

Future<void> _renameFolderDialog(BuildContext context, WidgetRef ref,
    DriveFolder folder, String parentUuid) async {
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
    final space = ref.read(selectedSpaceProvider);
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    if (parentUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(parentUuid));
    }
    showDriveToast('已重命名');
  } catch (e) {
    showDriveToast('重命名失败:$e', error: true);
  }
}

Future<void> _moveFolderDialog(BuildContext context, WidgetRef ref,
    DriveFolder folder, String parentUuid) async {
  // 排除"自己 + 全部后代"防自循环。后端也有同样校验,这里只是 UX 上灰显。
  final notifier = ref.read(driveTreeProvider.notifier);
  final space = _spaceUuidOf(ref, folder);
  final excludes = <String>[folder.uuid];
  // BFS 收集后代
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
  final targetUuid = await showFolderPickerDialog(
    context,
    ref,
    title: '移动目录到…',
    excludeUuids: excludes,
  );
  if (targetUuid == null) return; // null = 取消
  // 空字符串 = 移到 Space 根
  try {
    await ref.read(driveServiceProvider).moveFolder(
          folderUuid: folder.uuid,
          newParentUuid: targetUuid
        );
    await ref.read(driveTreeProvider.notifier).reloadSpace(space);
    if (parentUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(parentUuid));
    }
    if (targetUuid.isNotEmpty) {
      ref.invalidate(driveContentProvider(targetUuid));
    }
    showDriveToast('已移动');
  } catch (e) {
    showDriveToast('移动失败:$e', error: true);
  }
}

// ============================================================
//  KB 内容(右侧另一种渲染:KB 文档列表)
// ============================================================

class _KbContent extends ConsumerWidget {
  const _KbContent({
    required this.kbUuid,
    this.kbFolderUuid = '',
    required this.compactHeader,
    required this.space,
  });

  final String kbUuid;
  final String kbFolderUuid;
  final bool compactHeader;
  final String space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kbList =
        ref.watch(knowledgeKBListProvider(space)).value ?? const <KbItem>[];
    final kb = kbList.firstWhere(
      (k) => k.uuid == kbUuid,
      orElse: () => const KbItem(uuid: '', name: '', scope: '', status: ''),
    );
    if (kb.uuid.isEmpty) {
      return const _EmptyState(message: '知识库不存在或已被删除');
    }
    final foldersAsync = ref.watch(knowledgeFoldersProvider(kbUuid));
    final folders = foldersAsync.value ?? const <KbFolder>[];
    final folderTrail = _kbFolderTrail(folders, kbFolderUuid);
    final childFolders = folders
        .where((f) => f.parentUuid == kbFolderUuid)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final docsQuery = KnowledgeDocumentsQuery(
      kbUuid: kbUuid,
      kbFolderUuid: kbFolderUuid,
    );
    final asyncDocs = ref.watch(knowledgeDocumentsProvider(docsQuery));
    final isNarrow = _isDriveNarrow(context);
    final breadcrumbs = DriveBrowseFilter.maybeOf(context)?.breadcrumbs;
    final hPad = isNarrow ? 16.0 : 32.0;
    final breadcrumbLabels = _kbContentBreadcrumbCrumbs(
      context,
      ref,
      space,
      kb,
      folderTrail,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: breadcrumbs != null
              ? EdgeInsets.zero
              : EdgeInsets.fromLTRB(hPad, isNarrow ? 14 : 24, hPad, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (breadcrumbs != null)
                _DriveMobileToolbar(
                  breadcrumbs: breadcrumbs,
                  create: _DriveCreateMenuButton(
                    enabled: kb.canWrite,
                    onCreateFolder: () => _showCreateKbFolderDialog(
                        context, ref, kb,
                        parentUuid: kbFolderUuid),
                    onCreateDoc: () => showDriveToast('新建文档功能 M3 上线'),
                    folderLabel: '新建目录',
                    docLabel: '新建文档',
                  ),
                  importButton: _DriveImportMenuButton(
                    enabled: kb.canWrite,
                    onImportLocal: () => _uploadKbDocument(context, ref, kb,
                        kbFolderUuid: kbFolderUuid),
                    onImportFromChat: () => _linkFromDriveFlow(context, ref, kb,
                        kbFolderUuid: kbFolderUuid),
                    localLabel: '本地上传',
                    chatLabel: '从云盘加入',
                  ),
                )
              else if (isNarrow) ...[
                if (!compactHeader) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _driveBreadcrumbWidgets(breadcrumbLabels,
                          compact: isNarrow),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(
                      child: _DriveCreateMenuButton(
                        enabled: kb.canWrite,
                        onCreateFolder: () => _showCreateKbFolderDialog(
                          context,
                          ref,
                          kb,
                          parentUuid: kbFolderUuid,
                        ),
                        onCreateDoc: () => showDriveToast('新建文档功能 M3 上线'),
                        folderLabel: '新建目录',
                        docLabel: '新建文档',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DriveImportMenuButton(
                        enabled: kb.canWrite,
                        onImportLocal: () => _uploadKbDocument(context, ref, kb,
                            kbFolderUuid: kbFolderUuid),
                        onImportFromChat: () => _linkFromDriveFlow(
                            context, ref, kb,
                            kbFolderUuid: kbFolderUuid),
                        localLabel: '本地上传',
                        chatLabel: '从云盘加入',
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _driveBreadcrumbWidgets(breadcrumbLabels,
                              compact: isNarrow),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // + 新建 下拉(对齐设计文档 §6.2.D)
                    _DriveCreateMenuButton(
                      enabled: kb.canWrite,
                      onCreateFolder: () => _showCreateKbFolderDialog(
                        context,
                        ref,
                        kb,
                        parentUuid: kbFolderUuid,
                      ),
                      onCreateDoc: () => showDriveToast('新建文档功能 M3 上线'),
                      folderLabel: '新建目录',
                      docLabel: '新建文档',
                    ),
                    const SizedBox(width: 8),
                    // ↑ 导入 下拉(对齐设计文档 §6.2.D)
                    _DriveImportMenuButton(
                      enabled: kb.canWrite,
                      onImportLocal: () => _uploadKbDocument(context, ref, kb,
                          kbFolderUuid: kbFolderUuid),
                      onImportFromChat: () => _linkFromDriveFlow(
                          context, ref, kb,
                          kbFolderUuid: kbFolderUuid),
                      localLabel: '本地上传',
                      chatLabel: '从云盘加入',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: foldersAsync.isLoading && folders.isEmpty
              ? const Center(child: CupertinoActivityIndicator(radius: 12))
              : asyncDocs.when(
                  loading: () => const Center(
                      child: CupertinoActivityIndicator(radius: 12)),
                  error: (e, _) => _EmptyState(message: '加载失败:$e'),
                  data: (state) {
                    if (childFolders.isEmpty && state.items.isEmpty) {
                      return const _EmptyState(
                          message: '该目录还没有内容\n点击右上角新建目录、上传文档或从云盘加入');
                    }
                    return SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final f in childFolders)
                            _KbFolderCard(
                              kb: kb,
                              folder: f,
                              space: space
                            ),
                          if (!isNarrow && state.items.isNotEmpty)
                            const _KbDocsTableHeader(),
                          for (final d in state.items)
                            _KbDocRow(
                              doc: d,
                              kbUuid: kb.uuid,
                              kbFolderUuid: kbFolderUuid,
                              canWrite: kb.canWrite,
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

List<KbFolder> _kbFolderTrail(List<KbFolder> folders, String folderUuid) {
  if (folderUuid.isEmpty) return const [];
  final byUuid = {for (final f in folders) f.uuid: f};
  final out = <KbFolder>[];
  var cursor = byUuid[folderUuid];
  while (cursor != null) {
    out.insert(0, cursor);
    if (cursor.parentUuid.isEmpty) break;
    cursor = byUuid[cursor.parentUuid];
  }
  return out;
}

/// 前两段(我的空间/共享空间、知识库)跳知识库根列表；kb 名跳该知识库文档根；
/// 目录段逐级可跳，最后一段(当前所在层级)不可点。
List<_DriveCrumb> _kbContentBreadcrumbCrumbs(
  BuildContext context,
  WidgetRef ref,
  String space,
  KbItem kb,
  List<KbFolder> folderTrail,
) {
  final labels = <String>[
    space == 'org' ? '共享空间' : '我的空间',
    '知识库',
    kb.name,
    ...folderTrail.map((f) => f.name),
  ];
  void toKbRoot() => openDriveSelection(
        context,
        ref,
        selection: const DriveSelection(kind: DriveSelectionKind.kbRoot),
        space: space,
      );
  void toKb() => openDriveSelection(
        context,
        ref,
        selection: DriveSelection(kind: DriveSelectionKind.kb, kbUuid: kb.uuid),
        space: space,
      );
  return [
    for (var i = 0; i < labels.length; i++)
      _DriveCrumb(
        labels[i],
        i == labels.length - 1
            ? null
            : i < 2
                ? toKbRoot
                : i == 2
                    ? toKb
                    : () => openDriveSelection(
                          context,
                          ref,
                          selection: DriveSelection(
                            kind: DriveSelectionKind.kbFolder,
                            kbUuid: kb.uuid,
                            kbFolderUuid: folderTrail[i - 3].uuid,
                          ),
                          space: space,
                        ),
      ),
  ];
}

class _KbFolderCard extends ConsumerWidget {
  const _KbFolderCard({
    required this.kb,
    required this.folder,
    required this.space,
  });

  final KbItem kb;
  final KbFolder folder;
  final String space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNarrow = _isDriveNarrow(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 12 : 16,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => openDriveSelection(
          context,
          ref,
          selection: DriveSelection(
            kind: DriveSelectionKind.kbFolder,
            kbUuid: kb.uuid,
            kbFolderUuid: folder.uuid,
          ),
          space: space,
        ),
        child: Row(
          children: [
            const Icon(CupertinoIcons.folder_fill,
                size: 28, color: Color(0xFFFA8C16)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2329),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KbDocsTableHeader extends StatelessWidget {
  const _KbDocsTableHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('名称', style: _driveListHeaderStyle)),
          SizedBox(
            width: 96,
            child: Text('状态', style: _driveListHeaderStyle)
          ),
          SizedBox(
            width: 128,
            child: Text('更新时间', style: _driveListHeaderStyle),
          ),
          SizedBox(
            width: 48,
            child: Text('操作', style: _driveListHeaderStyle)
          ),
        ],
      ),
    );
  }
}

String _kbDocumentDownloadPath(String kbUuid, String docUuid) =>
    '/knowledge-bases/${Uri.encodeComponent(kbUuid)}'
    '/documents/${Uri.encodeComponent(docUuid)}/download';

bool _isImageKbDocument(KbDocument doc) {
  final mime = doc.mimeType.toLowerCase();
  if (mime.startsWith('image/')) return true;
  final name = doc.fileName.toLowerCase();
  return name.endsWith('.png') ||
      name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.gif') ||
      name.endsWith('.tif') ||
      name.endsWith('.tiff');
}

class _KbDocLeadingIcon extends StatelessWidget {
  const _KbDocLeadingIcon({
    required this.doc,
    required this.kbUuid
  });

  final KbDocument doc;
  final String kbUuid;

  @override
  Widget build(BuildContext context) {
    if (!_isImageKbDocument(doc)) {
      return DriveFileIcon(mimeType: doc.mimeType, name: doc.fileName);
    }
    final url = apiImageResolveUrl(_kbDocumentDownloadPath(kbUuid, doc.uuid));
    final fallback = DriveFileIcon(mimeType: doc.mimeType, name: doc.fileName);
    return UiNetworkImage(
      imageUrl: url,
      width: 44,
      height: 44,
      fit: BoxFit.cover,
      borderRadius: 8,
      cacheKey: 'kb-doc:${doc.uuid}:${doc.updatedAt.millisecondsSinceEpoch}',
      placeholderBuilder: (_, __) => fallback,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}

class _KbDocRow extends ConsumerWidget {
  const _KbDocRow({
    required this.doc,
    required this.kbUuid,
    required this.kbFolderUuid,
    required this.canWrite,
  });
  final KbDocument doc;
  final String kbUuid;
  final String kbFolderUuid;
  final bool canWrite;

  Color _statusColor(String s) {
    switch (s) {
      case 'ready':
        return const Color(0xFF52C41A);
      case 'failed':
        return Colors.red;
      case 'pending':
      case 'parsing':
      case 'indexing':
        return const Color(0xFFFA8C16);
      default:
        return const Color(0xFF8C8C8C);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNarrow = _isDriveNarrow(context);
    final statusColor = _statusColor(doc.status);
    final isFavorite = _isResourceFavorite(
      ref.watch(driveFavoritesProvider).value,
      targetKind: 'kb_document',
      targetUuid: doc.uuid,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _previewKbDoc(context, ref, doc),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? 12 : 16,
            vertical: isNarrow ? 12 : 14,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFEEEEEE)),
          ),
          child: Row(
            children: [
              _KbDocLeadingIcon(doc: doc, kbUuid: kbUuid),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(doc.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2329),
                        )),
                    const SizedBox(height: 2),
                    Text(
                      // 宽屏状态已经单独有一列彩色状态胶囊 (下方),这里不重复展示；
                      // sourceLabel 目前后端还没有"从云盘引用导入"这条路径,所有文档
                      // 落库 source_kind 都是同一个值,展示出来没有区分度,先不显示。
                      isNarrow
                          ? '${doc.sizeDisplay}  ·  ${doc.statusLabel}'
                          : doc.sizeDisplay,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8C8C8C)),
                    ),
                  ],
                ),
              ),
              if (!isNarrow)
                SizedBox(
                  width: 96,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        doc.statusLabel,
                        style: TextStyle(
                            fontSize: 12,
                            color: statusColor,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              if (!isNarrow)
                SizedBox(
                  width: 128,
                  child: Text(
                    _formatDate(doc.updatedAt),
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFF595959)),
                  ),
                ),
              SizedBox(
                width: 48,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: UiDropdownMenu<String>(
                    menuWidth: 160,
                    hoverRadius: 8,
                    items: [
                      const UiDropdownMenuItem(
                        value: 'download',
                        label: '下载',
                        icon: CupertinoIcons.cloud_download,
                      ),
                      UiDropdownMenuItem(
                        value: 'favorite',
                        label: isFavorite ? '取消收藏' : '收藏',
                        icon: isFavorite
                            ? CupertinoIcons.star_fill
                            : CupertinoIcons.star,
                      ),
                      const UiDropdownMenuItem(
                        value: 'search',
                        label: '内容检索',
                        icon: CupertinoIcons.search,
                      ),
                      if (canWrite)
                        const UiDropdownMenuItem(
                          value: 'rename',
                          label: '重命名',
                          icon: CupertinoIcons.pencil,
                        ),
                      if (canWrite)
                        const UiDropdownMenuItem(
                          value: 'delete',
                          label: '删除',
                          icon: CupertinoIcons.delete,
                          danger: true,
                        ),
                    ],
                    onSelected: (action) async {
                      switch (action) {
                        case 'download':
                          await _downloadKbDoc(context, ref, doc);
                        case 'favorite':
                          await _toggleFavorite(
                            ref,
                            targetKind: 'kb_document',
                            targetUuid: doc.uuid,
                            kbUuid: kbUuid,
                            isFavorite: isFavorite,
                          );
                        case 'search':
                          await _showKbSearchDialog(context, ref, kbUuid, doc);
                        case 'rename':
                          await _renameKbDocDialog(
                            context,
                            ref,
                            doc,
                            kbUuid,
                            kbFolderUuid,
                          );
                        case 'delete':
                          await _confirmRemoveKbDoc(
                            context,
                            ref,
                            doc,
                            kbUuid,
                            kbFolderUuid,
                          );
                      }
                    },
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        CupertinoIcons.ellipsis,
                        size: 16,
                        color: Color(0xFF8C8C8C),
                      ),
                    ),
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

Future<void> _previewKbDoc(
  BuildContext context,
  WidgetRef ref,
  KbDocument doc,
) async {
  if (_isImageKbDocument(doc)) {
    final url =
        apiImageResolveUrl(_kbDocumentDownloadPath(doc.kbUuid, doc.uuid));
    if (!context.mounted) return;
    showImagePreviewRoute<void>(
      context: context,
      useSafeArea: Theme.of(context).platform != TargetPlatform.iOS &&
          Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => UiImagePreviewDialog(fileUrl: url, cacheKey: doc.uuid),
    );
    return;
  }
  if (doc.fileUuid.isEmpty) {
    // 没有独立 drive file_uuid 的历史数据：跟"下载"菜单项走同一套 KB 专属解析逻辑。
    await _downloadKbDoc(context, ref, doc);
    return;
  }
  try {
    final url =
        await ref.read(driveServiceProvider).previewUrl(fileUuid: doc.fileUuid);
    final uri = Uri.parse(url.url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      showDriveToast('预览打开失败', error: true);
    }
  } catch (e) {
    showDriveToast('预览失败:$e', error: true);
  }
}

Future<void> _downloadKbDoc(
  BuildContext context,
  WidgetRef ref,
  KbDocument doc,
) async {
  if (doc.fileUuid.isEmpty) {
    try {
      final url =
          apiImageResolveUrl(_kbDocumentDownloadPath(doc.kbUuid, doc.uuid));
      final headers = await apiImageLoadHeaders(url);
      final resp = await Dio().get<List<int>>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          followRedirects: true,
        ),
      );
      final bytes = resp.data;
      if (bytes == null || bytes.isEmpty) {
        showDriveToast('下载失败', error: true);
        return;
      }
      final dir = await getTemporaryDirectory();
      final fileName = _safeTempFileName(doc.fileName, fallback: doc.uuid);
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFile.open(file.path);
      if (result.type != ResultType.done) {
        showDriveToast(
          result.message.trim().isNotEmpty ? result.message : '无法打开文件',
          error: true,
        );
      }
    } catch (e) {
      showDriveToast('下载失败:$e', error: true);
    }
    return;
  }
  try {
    final url = await ref.read(driveServiceProvider).previewUrl(
          fileUuid: doc.fileUuid,
          download: true
        );
    final uri = Uri.parse(url.url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      showDriveToast('下载失败', error: true);
    }
  } catch (e) {
    showDriveToast('下载失败:$e', error: true);
  }
}

String _safeTempFileName(String name, {required String fallback}) {
  final trimmed = name.trim().isNotEmpty ? name.trim() : fallback;
  final safe = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return safe.isNotEmpty ? safe : fallback;
}

Future<void> _renameKbDocDialog(
  BuildContext context,
  WidgetRef ref,
  KbDocument doc,
  String kbUuid,
  String kbFolderUuid,
) async {
  final result = await showUiInputDialog(
    context,
    title: '重命名文档',
    initialValue: doc.fileName,
  );
  if (result == null || result.isEmpty || result == doc.fileName) return;
  try {
    await ref.read(knowledgeServiceProvider).renameDocument(
          kbUuid: kbUuid,
          kbDocUuid: doc.uuid,
          title: result
        );
    await ref
        .read(knowledgeDocumentsProvider(KnowledgeDocumentsQuery(
          kbUuid: kbUuid,
          kbFolderUuid: kbFolderUuid),
        ).notifier)
        .reload();
    showDriveToast('已重命名');
  } catch (e) {
    showDriveToast('重命名失败:$e', error: true);
  }
}

Future<void> _showKbSearchDialog(
  BuildContext context,
  WidgetRef ref,
  String kbUuid,
  KbDocument doc,
) async {
  if (doc.status != 'ready') {
    showDriveToast('文档可用后才能内容检索', error: true);
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: _KbSearchDialog(kbUuid: kbUuid, docName: doc.fileName),
    ),
  );
}

class _KbSearchDialog extends ConsumerStatefulWidget {
  const _KbSearchDialog({
    required this.kbUuid,
    required this.docName
  });

  final String kbUuid;
  final String docName;

  @override
  ConsumerState<_KbSearchDialog> createState() => _KbSearchDialogState();
}

class _KbSearchDialogState extends ConsumerState<_KbSearchDialog> {
  final _queryController = TextEditingController();
  bool _loading = false;
  String _error = '';
  KbSearchResult? _result;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final result = await ref.read(knowledgeServiceProvider).search(
            kbUuid: widget.kbUuid,
            query: query,
            topK: 8
          );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '检索失败:$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return UiContentDialog(
      maxHeight: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
            child: UiSheetHeader(
              title: '内容检索 · ${widget.docName}',
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEDEFF2)),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
            child: Row(
              children: [
                Expanded(
                  child: UiInputField(
                    controller: _queryController,
                    autofocus: true,
                    hintText: '输入要检索的内容',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _loading ? null : _search,
                  child: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('检索'),
                ),
              ],
            ),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
              child: Builder(builder: (context) {
                if (_error.isNotEmpty) {
                  return Center(
                    child: Text(
                      _error,
                      style: const TextStyle(color: Color(0xFFF5222D)),
                    ),
                  );
                }
                if (result == null) {
                  return const Center(
                    child: Text(
                      '输入关键词后检索当前知识库内容',
                      style: TextStyle(color: Color(0xFF8C8C8C)),
                    ),
                  );
                }
                if (result.chunks.isEmpty) {
                  return const Center(
                    child: Text(
                      '没有匹配内容',
                      style: TextStyle(color: Color(0xFF8C8C8C)),
                    ),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: result.chunks.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Color(0xFFEDEFF2)),
                  itemBuilder: (context, index) {
                    final chunk = result.chunks[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '片段 ${chunk.chunkIndex + 1}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1F2329),
                                  ),
                                ),
                              ),
                              Text(
                                '相关度 ${chunk.score.toStringAsFixed(3)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF8C8C8C),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            chunk.content,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: Color(0xFF595959),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _uploadKbDocument(
  BuildContext context,
  WidgetRef ref,
  KbItem kb, {
  String kbFolderUuid = '',
  String refreshListScope = '',
}) async {
  final file = await ref.read(knowledgeDocumentPickerProvider)();
  if (file == null) return;
  if (!context.mounted) return;
  if (!isKnowledgeDocumentFileName(file.name)) {
    showDriveToast(knowledgeDocumentFormatHint, error: true);
    return;
  }
  try {
    await ref.read(knowledgeServiceProvider).uploadDocument(
          kbUuid: kb.uuid,
          filePath: file.path,
          fileName: file.name,
          kbFolderUuid: kbFolderUuid,
        );
  } catch (e) {
    showDriveToast('上传失败:${_knowledgeOperationError(e)}', error: true);
    return;
  }
  if (!context.mounted) return;
  try {
    await _refreshKnowledgeAfterMutation(
      ref,
      kbUuid: kb.uuid,
      kbFolderUuid: kbFolderUuid,
      listScope: refreshListScope,
    );
    BotToast.showText(text: '上传成功');
  } catch (_) {
    showDriveToast('上传成功，列表刷新失败，请稍后重试', error: true);
  }
}

Future<void> _refreshKnowledgeAfterMutation(
  WidgetRef ref, {
  required String kbUuid,
  String kbFolderUuid = '',
  String listScope = '',
}) async {
  if (listScope.isNotEmpty) {
    await ref.read(knowledgeKBListProvider(listScope).notifier).reload();
    return;
  }
  await ref
      .read(knowledgeDocumentsProvider(KnowledgeDocumentsQuery(
        kbUuid: kbUuid,
        kbFolderUuid: kbFolderUuid),
      ).notifier)
      .reload();
}

Future<void> _showCreateKbFolderDialog(
  BuildContext context,
  WidgetRef ref,
  KbItem kb, {
  String parentUuid = '',
}) async {
  final result = await showUiInputDialog(
    context,
    title: '新建知识库目录',
    hintText: '目录名称',
    confirmLabel: '创建',
  );
  if (result == null || result.isEmpty) return;
  if (!context.mounted) return;
  try {
    await ref.read(knowledgeServiceProvider).createFolder(
          kbUuid: kb.uuid,
          name: result,
          parentUuid: parentUuid
        );
    if (!context.mounted) return;
    await ref.read(knowledgeFoldersProvider(kb.uuid).notifier).reload();
    showDriveToast('创建成功');
  } catch (e) {
    showDriveToast('创建失败:${_knowledgeOperationError(e)}', error: true);
  }
}

Future<void> _showCreateKbDialog(
  BuildContext context,
  WidgetRef ref, {
  required String scope,
}) async {
  final result = await showUiInputDialog(
    context,
    title: scope == 'org' ? '新建共享知识库' : '新建知识库',
    hintText: '知识库名称',
    confirmLabel: '创建',
  );
  if (result == null || result.isEmpty) return;
  if (!context.mounted) return;
  try {
    await ref.read(knowledgeServiceProvider).createKB(
          name: result,
          space: scope
        );
    if (!context.mounted) return;
    await ref.read(knowledgeKBListProvider(scope).notifier).reload();
    showDriveToast('创建成功');
  } catch (e) {
    showDriveToast('创建失败:${_knowledgeOperationError(e)}', error: true);
  }
}

String _knowledgeOperationError(Object error) {
  final message = error.toString();
  if (message.contains('kb.provider_degraded')) {
    return '知识库服务不可用,请联系管理员检查 RAGFlow 配置';
  }
  if (message.contains('kb.document_format_unsupported')) {
    return knowledgeDocumentFormatHint;
  }
  if (message.contains('kb.permission_denied')) {
    return '你没有该共享知识库的编辑权限,请联系知识库创建者或租户管理员上传/授权';
  }
  return message;
}

bool _isKnowledgeSupportedDriveFile(DriveFile file) {
  return isKnowledgeDocumentMime(file.mimeType) ||
      isKnowledgeDocumentFileName(file.name);
}

Future<KbItem?> _pickKbForScope(
  BuildContext context,
  WidgetRef ref, {
  required String scope,
}) async {
  final kbUuid = await showKbPickerDialog(
    context,
    ref,
    space: scope,
    writableOnly: true,
  );
  if (kbUuid == null) return null;
  final list =
      ref.read(knowledgeKBListProvider(scope)).value ?? const <KbItem>[];
  for (final kb in list) {
    if (kb.uuid == kbUuid) return kb;
  }
  return null;
}

Future<void> _uploadDocumentFromKbRoot(
  BuildContext context,
  WidgetRef ref, {
  required String scope,
}) async {
  final kb = await _pickKbForScope(context, ref, scope: scope);
  if (!context.mounted) return;
  if (kb == null) {
    final list =
        ref.read(knowledgeKBListProvider(scope)).value ?? const <KbItem>[];
    if (list.isEmpty) showDriveToast('请先新建知识库');
    return;
  }
  await _uploadKbDocument(
    context,
    ref,
    kb,
    refreshListScope: scope
  );
}

Future<void> _linkDriveFileFromKbRoot(
  BuildContext context,
  WidgetRef ref, {
  required String scope,
}) async {
  final kb = await _pickKbForScope(context, ref, scope: scope);
  if (!context.mounted) return;
  if (kb == null) {
    final list =
        ref.read(knowledgeKBListProvider(scope)).value ?? const <KbItem>[];
    if (list.isEmpty) showDriveToast('请先新建知识库');
    return;
  }
  await _linkFromDriveFlow(
    context,
    ref,
    kb,
    refreshListScope: scope
  );
}

Future<void> _confirmRemoveKbDoc(
  BuildContext context,
  WidgetRef ref,
  KbDocument doc,
  String kbUuid,
  String kbFolderUuid,
) async {
  final ok = await showUiConfirmDialog(
    context,
    title: '从知识库移除',
    description: '从该知识库中移除「${doc.fileName}」?'
        '${doc.source == 'kb_upload' ? '\n该文档是 KB 内上传，移除后文件本身也会被清理。' : '\n云盘文件不会受影响。'}',
    confirmLabel: '移除',
    danger: true,
  );
  if (!ok) return;
  try {
    await ref
        .read(knowledgeServiceProvider)
        .deleteDocument(kbUuid: kbUuid, kbDocUuid: doc.uuid);
    await ref
        .read(knowledgeDocumentsProvider(KnowledgeDocumentsQuery(
          kbUuid: kbUuid,
          kbFolderUuid: kbFolderUuid),
        ).notifier)
        .reload();
    BotToast.showText(text: '已移除');
  } catch (e) {
    BotToast.showText(text: '移除失败:$e');
  }
}

// ============================================================
//  + 新建 / ↑ 导入 下拉菜单(云盘 + 知识库 共用,标签可定制)
// ============================================================

class _DriveCreateMenuButton extends StatelessWidget {
  const _DriveCreateMenuButton({
    required this.enabled,
    required this.onCreateFolder,
    required this.onCreateDoc,
    this.folderLabel = '新建文件夹',
    this.docLabel = '新建文档',
  });

  final bool enabled;
  final VoidCallback onCreateFolder;
  final VoidCallback onCreateDoc;
  final String folderLabel;
  final String docLabel;

  @override
  Widget build(BuildContext context) {
    return UiDropdownMenu<String>(
      enabled: enabled,
      menuWidth: 160,
      items: [
        UiDropdownMenuItem(
          value: 'folder',
          label: folderLabel,
          icon: CupertinoIcons.folder_badge_plus,
        ),
        UiDropdownMenuItem(
          value: 'doc',
          label: docLabel,
          icon: CupertinoIcons.doc_text,
        ),
      ],
      onSelected: (action) {
        switch (action) {
          case 'folder':
            onCreateFolder();
          case 'doc':
            onCreateDoc();
        }
      },
      child: DriveBrowseFilter.maybeOf(context) != null
          ? Tooltip(
              message: '新建',
              child: SizedBox(
                  key: const ValueKey('drive-create-trigger'),
                  width: 44,
                  height: 44,
                  child: Icon(CupertinoIcons.add,
                      size: 20,
                      color: enabled
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).disabledColor)))
          : AbsorbPointer(
              child: FilledButton.icon(
                onPressed: enabled ? () {} : null,
                icon: const Icon(CupertinoIcons.add, size: 16),
                label: const Text('新建'),
              ),
            ),
    );
  }
}

class _DriveImportMenuButton extends StatelessWidget {
  const _DriveImportMenuButton({
    required this.enabled,
    required this.onImportLocal,
    this.onImportLocalFolder,
    required this.onImportFromChat,
    this.localLabel = '导入本地文件',
    this.chatLabel = '导入聊天中的文件',
  });

  final bool enabled;
  final VoidCallback onImportLocal;

  /// 仅云盘目录上下文有意义，KB 不传（KB 是平铺，不递归建子目录）。
  final VoidCallback? onImportLocalFolder;
  final VoidCallback onImportFromChat;
  final String localLabel;
  final String chatLabel;

  @override
  Widget build(BuildContext context) {
    return UiDropdownMenu<String>(
      enabled: enabled,
      menuWidth: 180,
      items: [
        UiDropdownMenuItem(
          value: 'local',
          label: localLabel,
          icon: CupertinoIcons.doc_text,
        ),
        if (onImportLocalFolder != null)
          const UiDropdownMenuItem(
            value: 'localFolder',
            label: '导入本地文件夹',
            icon: CupertinoIcons.folder,
          ),
        UiDropdownMenuItem(
          value: 'chat',
          label: chatLabel,
          icon: CupertinoIcons.chat_bubble_2,
        ),
      ],
      onSelected: (action) {
        switch (action) {
          case 'local':
            onImportLocal();
          case 'localFolder':
            onImportLocalFolder?.call();
          case 'chat':
            onImportFromChat();
        }
      },
      child: DriveBrowseFilter.maybeOf(context) != null
          ? Tooltip(
              message: '导入',
              child: SizedBox(
                  key: const ValueKey('drive-import-trigger'),
                  width: 44,
                  height: 44,
                  child: Icon(CupertinoIcons.cloud_upload,
                      size: 20,
                      color: enabled
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).disabledColor)))
          : AbsorbPointer(
              child: OutlinedButton.icon(
                onPressed: enabled ? () {} : null,
                icon: const Icon(CupertinoIcons.cloud_upload, size: 16),
                label: const Text('导入'),
              ),
            ),
    );
  }
}

// ============================================================
//  从云盘加入 KB:弹 drive picker → linkFromDrive
// ============================================================

// ============================================================
//  从聊天文件导入到当前 drive 目录:弹 chat-import → importFromChat
// ============================================================

Future<void> _importFromChatFlow(
    BuildContext context, WidgetRef ref, DriveFolder folder) async {
  // 系统目录(de_root / de_agent / de_outputs)不允许导入,菜单理应不显示;
  // 兜底再判一次,免得调用方未来漏了。
  if (!folder.isRegular) {
    showDriveToast('当前目录不支持导入文件', error: true);
    return;
  }
  final picked = await showDriveChatImportDialog(context, ref);
  if (picked == null || picked.isEmpty) return;
  try {
    final imported = await ref.read(driveServiceProvider).importFromChat(
          targetFolderUuid: folder.uuid,
          driveFileUuids: picked
        );
    // 刷新当前目录,让导入的文件立刻出现
    ref.invalidate(driveContentProvider(folder.uuid));
    // 「最近使用」也跟着脏掉
    ref.invalidate(driveRecentFilesProvider);
    showDriveToast('已导入 ${imported.length} / ${picked.length} 个文件');
  } catch (e) {
    showDriveToast('导入失败:$e', error: true);
  }
}

Future<void> _linkFromDriveFlow(
  BuildContext context,
  WidgetRef ref,
  KbItem kb, {
  String kbFolderUuid = '',
  String refreshListScope = '',
}) async {
  final picked = await showDriveFilePicker(context, ref);
  if (picked == null || picked.isEmpty) return;
  if (!context.mounted) return;
  final unsupported =
      picked.where((f) => !_isKnowledgeSupportedDriveFile(f)).toList();
  if (unsupported.isNotEmpty) {
    showDriveToast(knowledgeDocumentFormatHint, error: true);
    return;
  }
  final fileUuids = picked.map((f) => f.uuid).toList(growable: false);
  try {
    await ref.read(knowledgeServiceProvider).linkFromDrive(
          kbUuid: kb.uuid,
          fileUuids: fileUuids,
          kbFolderUuid: kbFolderUuid,
        );
  } catch (e) {
    BotToast.showText(text: '加入失败:${_knowledgeOperationError(e)}');
    return;
  }
  if (!context.mounted) return;
  try {
    await _refreshKnowledgeAfterMutation(
      ref,
      kbUuid: kb.uuid,
      kbFolderUuid: kbFolderUuid,
      listScope: refreshListScope,
    );
    BotToast.showText(text: '已加入 ${fileUuids.length} 个文件');
  } catch (_) {
    showDriveToast('文件已加入，列表刷新失败，请稍后重试', error: true);
  }
}

// ============================================================
//  云盘图片缩略图（异步获取 presigned URL 后展示）
// ============================================================
