import 'package:zhiban_client/pages/drive/widgets/drive_browse_filter.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 手机首页接管目录浏览，文件预览/编辑等独立流程仍由各自入口处理。
class DriveNavigationScope extends InheritedWidget {
  const DriveNavigationScope({
    super.key,
    required this.onOpenSelection,
    required this.onOpenSpace,
    required super.child,
  });

  final void Function(DriveSelection selection, String space) onOpenSelection;
  final ValueChanged<String> onOpenSpace;

  static DriveNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DriveNavigationScope>();

  @override
  bool updateShouldNotify(DriveNavigationScope oldWidget) =>
      onOpenSelection != oldWidget.onOpenSelection ||
      onOpenSpace != oldWidget.onOpenSpace;
}

void openDriveSpace(BuildContext context, String space) {
  final navigation = DriveNavigationScope.maybeOf(context);
  if (navigation != null) {
    navigation.onOpenSpace(space);
    return;
  }
  context.push(Uri(
      path: RoutePaths.driveDetail,
      queryParameters: {'kind': 'space', 'space': space}).toString());
}

void openDriveSelection(
  BuildContext context,
  WidgetRef ref, {
  required DriveSelection selection,
  required String space,
  bool asPage = false,
}) {
  final navigation = DriveNavigationScope.maybeOf(context);
  if (navigation != null) {
    navigation.onOpenSelection(selection, space);
    return;
  }

  ref.read(selectedSpaceProvider.notifier).state = space;
  ref.read(driveSelectionProvider.notifier).state = selection;

  // 非首页的既有移动入口保留 root route 兼容。
  final mobilePage = asPage ||
      DriveBrowseFilter.maybeOf(context) != null ||
      (PlatformUtils.isMobile &&
          MediaQuery.sizeOf(context).width < PlatformUtils.tabletBreakpoint);
  if (mobilePage && selection.kind != DriveSelectionKind.none) {
    context
        .push(_driveDetailUri(selection: selection, space: space).toString());
  }
}

Uri _driveDetailUri({
  required DriveSelection selection,
  required String space,
}) {
  final query = <String, String>{'space': space};
  switch (selection.kind) {
    case DriveSelectionKind.driveRoot:
      query['kind'] = 'drive_root';
    case DriveSelectionKind.kbRoot:
      query['kind'] = 'kb_root';
    case DriveSelectionKind.driveFolder:
      query['kind'] = 'folder';
      query['id'] = selection.folderUuid;
    case DriveSelectionKind.kb:
      query['kind'] = 'kb';
      query['id'] = selection.kbUuid;
    case DriveSelectionKind.kbFolder:
      query['kind'] = 'kb_folder';
      query['id'] = selection.kbFolderUuid;
      query['kb_uuid'] = selection.kbUuid;
    case DriveSelectionKind.recent:
      query['kind'] = 'recent';
    case DriveSelectionKind.favorite:
      query['kind'] = 'favorite';
    case DriveSelectionKind.recycle:
      query['kind'] = 'recycle';
    case DriveSelectionKind.none:
      query['kind'] = 'none';
  }
  return Uri(path: RoutePaths.driveDetail, queryParameters: query);
}
