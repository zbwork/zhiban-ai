import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../chat/widgets/local_agent_controls.dart'
    show
        AgentControlButton,
        permissionLabels,
        localWarningColor,
        localPermissionMenuItems,
        FullLocalAccessDialog;
import 'local_model_picker.dart';
import 'services/local_workspace_store.dart';
import 'package:file_selector/file_selector.dart';
import 'package:bot_toast/bot_toast.dart';

class LocalChatModelControl extends StatelessWidget {
  const LocalChatModelControl(
      {super.key,
      required this.employee,
      required this.busy,
      this.onWorkspace,
      required this.permissionMode,
      required this.onPermission,
      required this.onSelect});
  final LocalRow employee;
  final bool busy;
  final String permissionMode;
  final Future<void> Function(String mode) onPermission;
  final Future<void> Function(String path)? onWorkspace;
  final Future<void> Function(String provider, String model) onSelect;

  @override
  Widget build(BuildContext context) {
    final meta = jsonDecode(employee['metadata'] as String? ?? '{}') as Map;
    final workspace = meta['workspace'] as String?;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (onWorkspace != null)
            Tooltip(
              message: workspace ?? '选择工作目录',
              child: AgentControlButton(
                  label: workspace == null
                      ? '工作目录'
                      : workspace
                              .split(RegExp(r'[/\\]'))
                              .where((part) => part.isNotEmpty)
                              .lastOrNull ??
                          workspace,
                  icon: CupertinoIcons.folder,
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            final path = await getDirectoryPath(
                                initialDirectory: workspace,
                                confirmButtonText: '使用此工作目录');
                            if (path != null) {
                              await onWorkspace!(path);
                            }
                          } catch (_) {
                            BotToast.showText(text: '工作目录选择或保存失败，请重试');
                          }
                        }),
            ),
          Builder(
              builder: (anchor) => AgentControlButton(
                    key: const ValueKey('local-chat-permission-button'),
                    label: permissionLabels[permissionMode]!,
                    icon: CupertinoIcons.shield,
                    color: permissionMode == 'full'
                        ? localWarningColor(context)
                        : null,
                    onPressed: busy
                        ? null
                        : () async {
                            final box = anchor.findRenderObject() as RenderBox;
                            final overlay = Overlay.of(context)
                                .context
                                .findRenderObject() as RenderBox;
                            final point = box.localToGlobal(Offset.zero,
                                ancestor: overlay);
                            final y = (point.dy - 310)
                                .clamp(8.0, overlay.size.height - 80);
                            final width =
                                310.0.clamp(0.0, overlay.size.width - 32);
                            final choice = await showMenu<String>(
                                context: context,
                                position: RelativeRect.fromLTRB(
                                    point.dx,
                                    y,
                                    overlay.size.width -
                                        point.dx -
                                        box.size.width,
                                    overlay.size.height - y),
                                constraints: BoxConstraints(
                                    minWidth: width, maxWidth: width),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                color: Theme.of(context).colorScheme.surface,
                                items: localPermissionMenuItems(
                                    context, permissionMode));
                            if (choice == null ||
                                choice == permissionMode ||
                                !context.mounted) {
                              return;
                            }
                            if (choice == 'full') {
                              final accepted = await showDialog<bool>(
                                  context: context,
                                  builder: (_) =>
                                      const FullLocalAccessDialog());
                              if (accepted != true || !context.mounted) return;
                            }
                            try {
                              await onPermission(choice);
                            } catch (_) {
                              BotToast.showText(text: '访问权限保存失败，请重试');
                            }
                          },
                  )),
          LocalModelPicker(
            key: const ValueKey('local-chat-model-button'),
            selected:
                jsonEncode([employee['provider_id'], employee['model_id']]),
            busy: busy,
            onSelected: (model) => onSelect(model.providerId, model.modelId),
          ),
        ]),
      ),
    );
  }
}
