import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

/// 目录选择对话框。当前 Space 下所有 regular 目录可点击;
/// 系统目录(de_root / de_agent / de_outputs)灰显不可点。
///
/// excludeUuids 内的目录也禁用,用于 moveFolder 时排除"自己 + 后代"。
///
/// 注意:本应用 ProviderScope 包在 MaterialApp.builder 里,root Navigator
/// 在 ProviderScope 之上;showDialog 默认走 root Navigator,dialog 子树
/// 拿不到 ProviderScope。这里复用 skills_page.dart 的方案:在调用方拿到
/// container,用 UncontrolledProviderScope 在 dialog 子树里重新挂上。
Future<String?> showFolderPickerDialog(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择目录',
  List<String> excludeUuids = const [],
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (ctx, ref, _) {
          final treeAsync = ref.watch(driveTreeProvider);
          final space = ref.read(selectedSpaceProvider);
          return UiPickerDialog(
            size: UiDialogSize.compact,
            maxHeight: 560,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
                  child: UiSheetHeader(
                    title: title,
                    onClose: () => Navigator.of(ctx).pop(),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: treeAsync.when(
                    loading: () => const Center(
                      child: CupertinoActivityIndicator(radius: 12),
                    ),
                    error: (e, _) => Center(child: Text('加载失败:$e')),
                    data: (state) {
                      final folders = state.foldersFor(space);
                      if (folders.isEmpty) {
                        return const Center(child: Text('当前空间下没有目录'));
                      }
                      final sorted = [...folders]
                        ..sort((a, b) => a.path.compareTo(b.path));
                      return ListView(
                        children: [
                          for (final f in sorted)
                            _FolderPickerRow(
                              folder: f,
                              disabled: f.isSystem ||
                                  !f.isRegular ||
                                  excludeUuids.contains(f.uuid),
                              onTap: () => Navigator.of(ctx).pop(f.uuid),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(''),
                        child: const Text('移到根目录'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      );
    },
  );
}

class _FolderPickerRow extends StatelessWidget {
  const _FolderPickerRow({
    required this.folder,
    required this.disabled,
    required this.onTap,
  });

  final DriveFolder folder;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = disabled ? Colors.grey : null;
    return ListTile(
      enabled: !disabled,
      dense: true,
      leading: Icon(Icons.folder, color: color ?? const Color(0xFFFA8C16)),
      title: Text(
        folder.name,
        style: TextStyle(color: color)
      ),
      subtitle: Text(
        folder.path.isEmpty ? '/' : folder.path,
        style: TextStyle(fontSize: 11, color: color ?? const Color(0xFF8C8C8C)),
      ),
      onTap: disabled ? null : onTap,
    );
  }
}
