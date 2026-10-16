import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:zhiban_client/pages/knowledge/providers/knowledge_providers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';

/// 弹一个 KB 列表对话框(当前 Space 下所有 KB),返回选中的 KB UUID。
/// 取消返回 null。
///
/// 视觉与「选择云盘文件」「导入聊天文件」弹框保持同一套:圆角卡片 / 标题 + 副标题 +
/// 关闭按钮 / 底部「取消 + 确定」。每个 KB 行是大块卡片 + 紫色 avatar + 右侧单选圆点,
/// 用户先选后点确定(单击行=选中,不再立即关弹框)。
///
/// 注意:dialog 子树要显式带 ProviderScope,见 folder_picker.dart 注释。
Future<String?> showKbPickerDialog(
  BuildContext context,
  WidgetRef ref, {
  String? space,
  bool writableOnly = false,
}) async {
  final effectiveSpace = space ?? _kbScopeFromSelectedDriveSpace(ref);
  final container = ProviderScope.containerOf(context, listen: false);
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) {
      return UncontrolledProviderScope(
        container: container,
        child: _KbPickerDialog(
          space: effectiveSpace,
          writableOnly: writableOnly,
        ),
      );
    },
  );
}

String _kbScopeFromSelectedDriveSpace(WidgetRef ref) {
  final selected = ref.read(selectedSpaceProvider);
  if (selected == 'org' || selected == 'personal') return selected;
  final tree = ref.read(driveTreeProvider).value;
  if (tree == null) return 'personal';
  for (final sp in tree.orgSpaces) {
    if (sp.uuid == selected) return 'org';
  }
  return 'personal';
}

class _KbPickerDialog extends ConsumerStatefulWidget {
  const _KbPickerDialog({
    required this.space,
    required this.writableOnly
  });
  final String space;
  final bool writableOnly;

  @override
  ConsumerState<_KbPickerDialog> createState() => _KbPickerDialogState();
}

class _KbPickerDialogState extends ConsumerState<_KbPickerDialog> {
  String _selectedUuid = '';

  @override
  Widget build(BuildContext context) {
    final asyncList = ref.watch(knowledgeKBListProvider(widget.space));
    return UiPickerDialog(
      size: UiDialogSize.standard,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
              child: asyncList.when(
                loading: () => const SizedBox(
                  height: 120,
                  child: Center(child: CupertinoActivityIndicator(radius: 12)),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('加载失败:$e',
                      style: const TextStyle(color: Color(0xFFE5484D))),
                ),
                data: (list) {
                  final items = widget.writableOnly
                      ? list.where((kb) => kb.canWrite).toList()
                      : list;
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          widget.writableOnly
                              ? '当前空间下没有可编辑的知识库'
                              : '当前空间下没有可用的知识库',
                          style: const TextStyle(color: Color(0xFF8C8C8C)),
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final kb = items[i];
                      return _KbCard(
                        kb: kb,
                        selected: kb.uuid == _selectedUuid,
                        onTap: () => setState(() => _selectedUuid = kb.uuid),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: UiSheetHeader(
        title: '选择知识库',
        subtitle: '请选择要关联的知识库',
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final hasSelection = _selectedUuid.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: hasSelection
                ? () => Navigator.pop(context, _selectedUuid)
                : null,
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

class _KbCard extends StatelessWidget {
  const _KbCard({
    required this.kb,
    required this.selected,
    required this.onTap,
  });
  final KbItem kb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF722ED1);
    const purpleSoft = Color(0xFFF3EEFF);
    final borderColor = selected ? purple : const Color(0xFFE8E8E8);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? purpleSoft : Colors.white,
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              _KbAvatar(kb: kb),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      kb.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1F2329),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      kb.isShared ? '共享知识库' : 'Agent 专属知识库',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF8C8C8C),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Radio(selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

/// 紫色圆形 avatar:agent KB 优先用真实头像,失败/共享 KB 回退到 emoji 风图标。
class _KbAvatar extends StatelessWidget {
  const _KbAvatar({required this.kb});
  final KbItem kb;

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF722ED1);
    const purpleSoft = Color(0xFFEDE2FF);
    final fallback = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: purpleSoft,
        borderRadius: BorderRadius.circular(22),
      ),
      alignment: Alignment.center,
      child: Icon(
        kb.isShared
            ? CupertinoIcons.globe
            : CupertinoIcons.person_crop_circle_fill,
        size: 24,
        color: purple,
      ),
    );
    if (kb.isAgent && kb.avatarUrl.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          kb.avatarUrl,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
    }
    return fallback;
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF722ED1);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? purple : const Color(0xFFD9D9D9),
          width: selected ? 6 : 1.5,
        ),
        color: Colors.white,
      ),
    );
  }
}
