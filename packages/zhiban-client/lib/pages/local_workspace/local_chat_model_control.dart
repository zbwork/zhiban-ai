import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import '../../routes/route_paths.dart';
import '../../services/conversation_models.dart';
import '../chat/widgets/local_agent_controls.dart'
    show AgentControlButton, conversationModelIcon, conversationModelPlatform;
import '../chat/widgets/model_picker_content.dart';
import '../model_service/providers/model_service_providers.dart';
import '../model_service/services/model_modality_classifier.dart';
import 'services/local_workspace_store.dart';
import 'package:file_selector/file_selector.dart';
import 'package:bot_toast/bot_toast.dart';

class LocalChatModelControl extends ConsumerWidget {
  const LocalChatModelControl(
      {super.key,
      required this.employee,
      required this.busy,
      this.onWorkspace,
      required this.onSelect});
  final LocalRow employee;
  final bool busy;
  final Future<void> Function(String path)? onWorkspace;
  final Future<void> Function(String provider, String model) onSelect;

  Future<ConversationModelState> _models(WidgetRef ref) async {
    final providers = await ref.read(modelProvidersProvider.future);
    final catalog = await ref.read(modelCatalogProvider.future);
    return ConversationModelState(
      selected: jsonEncode([employee['provider_id'], employee['model_id']]),
      models: [
        for (final p in providers.where((p) => p.enabled))
          for (final m in p.models.where((m) =>
              m.enabled && classifyModelId(m.modelId) == ModelModality.text))
            LlmModelOption(
                id: jsonEncode([p.id, m.modelId]),
                label: m.displayName,
                modelId: m.modelId,
                providerId: p.id,
                providerName: p.name,
                providerIconAssetPath: catalog.providers
                    .where((entry) => entry.id == p.catalogId)
                    .firstOrNull
                    ?.iconAssetPath),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(modelProvidersProvider).value ?? [];
    final provider = providers
        .where((p) => p.id == employee['provider_id'] && p.enabled)
        .firstOrNull;
    final model = provider?.models
        .where((m) => m.modelId == employee['model_id'] && m.enabled)
        .firstOrNull;
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
          AgentControlButton(
            key: const ValueKey('local-chat-model-button'),
            label: model?.displayName ?? '选择模型',
            icon: CupertinoIcons.sparkles,
            leading: model == null
                ? null
                : conversationModelIcon(context, model.modelId, size: 22),
            onPressed: busy
                ? null
                : () async {
                    final overlay = Overlay.of(context)
                        .context
                        .findRenderObject() as RenderBox;
                    final button = context.findRenderObject() as RenderBox;
                    final position =
                        button.localToGlobal(Offset.zero, ancestor: overlay);
                    final maxHeight =
                        (overlay.size.height - 40).clamp(0.0, 616.0);
                    final height =
                        (overlay.size.height - 44).clamp(0.0, maxHeight);
                    final y = (position.dy - height - 8)
                        .clamp(8.0, overlay.size.height - 80);
                    final width = 440.0.clamp(0.0, overlay.size.width - 32);
                    final state = await _models(ref);
                    if (!context.mounted) return;
                    final picked = await showMenu<String>(
                      context: context,
                      constraints: BoxConstraints(
                          minWidth: width,
                          maxWidth: width,
                          maxHeight: maxHeight),
                      position: RelativeRect.fromLTRB(
                          position.dx,
                          y,
                          overlay.size.width - position.dx - button.size.width,
                          overlay.size.height - y),
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                              color: UiFieldStyle.enabledBorderColor(
                                  Theme.of(context).colorScheme))),
                      color: Theme.of(context).colorScheme.surface,
                      items: [
                        ModelPickerEntry(
                          height: (overlay.size.height - 56).clamp(0.0, 600.0),
                          models: state.models,
                          selected: state.selected,
                          error: '',
                          modelIcon: (id) {
                            final option = state.models
                                .where((m) => m.id == id)
                                .firstOrNull;
                            return conversationModelIcon(
                                context, option?.modelId ?? id);
                          },
                          platform: (m) =>
                              conversationModelPlatform(context, m),
                          onRefresh: () => _models(ref),
                        )
                      ],
                    );
                    if (picked == null || !context.mounted) return;
                    if (picked == '@settings') {
                      context.go(RoutePaths.modelService);
                      return;
                    }
                    final selected =
                        state.models.where((m) => m.id == picked).firstOrNull;
                    if (selected != null) {
                      await onSelect(selected.providerId, selected.modelId);
                    }
                  },
          ),
        ]),
      ),
    );
  }
}
