import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import '../../routes/route_paths.dart';
import '../../services/conversation_models.dart';
import '../chat/widgets/local_agent_controls.dart'
    show AgentControlButton, conversationModelIcon, conversationModelPlatform;
import '../chat/widgets/model_picker_content.dart';
import '../model_service/models/ai_provider_config.dart';
import '../model_service/providers/model_service_providers.dart';
import '../model_service/services/model_catalog_loader.dart';
import '../model_service/services/model_modality_classifier.dart';

List<LlmModelOption> localTextModelOptions(List<AiProviderConfig> providers,
        {ModelCatalog? catalog}) =>
    [
      for (final provider in providers)
        if (provider.enabled)
          for (final model in provider.models)
            if (model.enabled &&
                classifyModelId(model.modelId) == ModelModality.text)
              LlmModelOption(
                id: jsonEncode([provider.id, model.modelId]),
                label: model.displayName,
                modelId: model.modelId,
                providerId: provider.id,
                providerName: provider.name,
                providerIconAssetPath: catalog?.providers
                    .where((entry) => entry.id == provider.catalogId)
                    .firstOrNull
                    ?.iconAssetPath,
              ),
    ];

class LocalModelPicker extends ConsumerStatefulWidget {
  const LocalModelPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.busy = false,
    this.openBelow = false,
    this.switchHint = '切换后从下一条消息生效',
  });

  final String? selected;
  final Future<void> Function(LlmModelOption) onSelected;
  final bool busy;
  final bool openBelow;
  final String switchHint;

  @override
  ConsumerState<LocalModelPicker> createState() => _LocalModelPickerState();
}

class _LocalModelPickerState extends ConsumerState<LocalModelPicker> {
  bool _open = false;

  Future<void> _showPicker() async {
    if (_open) return;
    setState(() => _open = true);
    try {
      final button = context.findRenderObject() as RenderBox;
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      final bounds =
          button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
      final below = math.max(0.0, overlay.size.height - bounds.bottom - 20);
      final above = math.max(0.0, bounds.top - 20);
      final opensBelow = widget.openBelow
          ? below >= 300 || below >= above
          : above < 300 && below > above;
      final space = opensBelow ? below : above;
      final height = math.min(616.0,
          space >= 350 ? space : math.max(0.0, overlay.size.height - 32));
      final width = math.max(0.0, math.min(440.0, overlay.size.width - 32));
      final preferredTop =
          opensBelow ? bounds.bottom + 6 : bounds.top - height - 6;
      final top = preferredTop
          .clamp(8.0, math.max(8.0, overlay.size.height - height - 8))
          .toDouble();
      final scheme = Theme.of(context).colorScheme;
      final selected = widget.selected ?? '';
      final switchHint = widget.switchHint;

      List<LlmModelOption> options(List<AiProviderConfig> providers) =>
          localTextModelOptions(providers,
              catalog: ref.read(modelCatalogProvider).value);
      var models = options(await ref.read(modelProvidersProvider.future));
      if (!mounted) return;
      final picked = await showMenu<String>(
        context: context,
        constraints: BoxConstraints.tightFor(width: width),
        position: RelativeRect.fromLTRB(bounds.left, top,
            overlay.size.width - bounds.right, overlay.size.height - top),
        elevation: 4,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: UiFieldStyle.enabledBorderColor(scheme))),
        color: scheme.surface,
        items: [
          ModelPickerEntry(
            height: math.max(0, height - 16),
            models: models,
            selected: selected,
            error: '',
            switchHint: switchHint,
            modelIcon: (id) => conversationModelIcon(context, id),
            platform: (model) => conversationModelPlatform(context, model),
            onRefresh: () async {
              final providers =
                  await ref.refresh(modelProvidersProvider.future);
              if (!mounted) return const ConversationModelState();
              models = options(providers);
              return ConversationModelState(
                  selected: widget.selected ?? '', models: models);
            },
          ),
        ],
      );
      if (!mounted || picked == null) return;
      if (picked == '@settings') {
        context.go(RoutePaths.modelService);
        return;
      }
      final option = models.where((model) => model.id == picked).firstOrNull;
      if (option != null) await widget.onSelected(option);
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = ref.watch(modelProvidersProvider).value ?? const [];
    ref.watch(modelCatalogProvider);
    final model = localTextModelOptions(providers)
        .where((model) => model.id == widget.selected)
        .firstOrNull;
    final label = model?.label ?? '选择模型';
    return Tooltip(
      message: label,
      child: AgentControlButton(
        label: label,
        icon: CupertinoIcons.sparkles,
        leading: model == null
            ? null
            : conversationModelIcon(context, model.modelId, size: 22),
        expanded: _open,
        onPressed: widget.busy ? null : _showPicker,
      ),
    );
  }
}
