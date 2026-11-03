import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/services/model_modality_classifier.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_field_style.dart';
import 'package:zhiban_client/pages/chat/widgets/model_picker_content.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart'
    show AgentControlButton, conversationModelIcon, conversationModelPlatform;
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/routes/route_paths.dart';

Future<bool?> showLocalCodingApiSettings(
  BuildContext context,
  LocalCodingVendor vendor, {
  LocalCodingBridgeSessionFactory? sessionFactory,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) =>
          _ApiSettings(vendor: vendor, sessionFactory: sessionFactory),
    );

class _ApiSettings extends StatefulWidget {
  const _ApiSettings({required this.vendor, this.sessionFactory});
  final LocalCodingVendor vendor;
  final LocalCodingBridgeSessionFactory? sessionFactory;
  @override
  State<_ApiSettings> createState() => _ApiSettingsState();
}

class _ApiSettingsState extends State<_ApiSettings> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<({AiProviderConfig provider, AiModelConfig model})> _models = [];
  String? _selectedModel;
  final _modelBaseUrls = <String, String>{};
  String? _selectedUrl;
  String? _selectedModelId;
  LocalCodingBridgeSessionFactory get _sessionFactory =>
      widget.sessionFactory ?? ProcessLocalCodingBridgeSessionFactory();

  String _optionId(AiProviderConfig provider, AiModelConfig model) =>
      '${provider.id}/${model.id}';

  void _selectModel(String? id) {
    _selectedModel = id;
    final option =
        _models.where((o) => _optionId(o.provider, o.model) == id).firstOrNull;
    if (option == null) return;
    _selectedUrl = _modelBaseUrls[option.provider.id];
    _selectedModelId = option.model.modelId;
    _error = null;
  }

  void _manageModels() {
    final router = GoRouter.of(context);
    Navigator.of(context).pop(false);
    router.go(RoutePaths.modelService);
  }

  Future<void> _refreshModels() async {
    final providers = await const ModelServiceStore().loadProviders();
    final catalog = await const ModelCatalogLoader().load();
    if (!mounted) return;
    final protocol = widget.vendor == LocalCodingVendor.codex
        ? AiEndpointType.openaiCompatible
        : AiEndpointType.anthropicMessages;
    _modelBaseUrls.clear();
    for (final provider in providers) {
      final baseUrl = catalog.localToolBaseUrlFor(provider, protocol);
      if (baseUrl != null) _modelBaseUrls[provider.id] = baseUrl;
    }
    _models = [
      for (final provider in providers)
        if (provider.enabled &&
            provider.baseUrl.isNotEmpty &&
            provider.customHeaders.isEmpty &&
            _modelBaseUrls.containsKey(provider.id))
          for (final model in provider.models)
            if (model.enabled &&
                classifyModelId(model.modelId) == ModelModality.text)
              (provider: provider, model: model)
    ];
  }

  Future<void> _openModelPicker(BuildContext anchor) async {
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox;
    final button = anchor.findRenderObject() as RenderBox;
    final rect =
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
    final width = 440.0.clamp(0.0, overlay.size.width - 32);
    final height = (overlay.size.height - 80).clamp(0.0, 600.0);
    ConversationModelState state() =>
        ConversationModelState(selected: _selectedModel ?? '', models: [
          for (final o in _models)
            LlmModelOption(
                id: _optionId(o.provider, o.model),
                label: o.model.displayName,
                modelId: o.model.modelId,
                providerId: o.provider.id,
                providerName: o.provider.name),
        ]);
    final models = state();
    final picked = await showMenu<String>(
        context: anchor,
        position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
        constraints: BoxConstraints(
            minWidth: width, maxWidth: width, maxHeight: height + 16),
        elevation: 4,
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
                color: UiFieldStyle.enabledBorderColor(
                    Theme.of(context).colorScheme))),
        items: [
          ModelPickerEntry(
              height: height,
              models: models.models,
              selected: models.selected,
              error: '',
              onRefresh: () async {
                await _refreshModels();
                return state();
              },
              modelIcon: (id) {
                final option = _models
                    .where((o) => _optionId(o.provider, o.model) == id)
                    .firstOrNull;
                return conversationModelIcon(
                    context, option?.model.modelId ?? id);
              },
              platform: (m) => conversationModelPlatform(context, m))
        ]);
    if (!mounted || picked == null) return;
    if (picked == '@settings') {
      _manageModels();
      return;
    }
    setState(() => _selectModel(picked));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    LocalCodingBridgeSession? session;
    try {
      session = await _sessionFactory.open();
      final info = await session.byokSettings(target: widget.vendor.cliTarget);
      if (!mounted) return;
      await _refreshModels();
      if (!mounted) return;
      setState(() {
        final existing = _models
            .where((o) =>
                _modelBaseUrls[o.provider.id] == info['base_url'] &&
                o.model.modelId == info['model'])
            .firstOrNull;
        if (existing != null) {
          _selectModel(_optionId(existing.provider, existing.model));
        } else if (info['key_configured'] != true && _models.isNotEmpty) {
          _selectModel(_optionId(_models.first.provider, _models.first.model));
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法读取本机 API 设置，请检查本地连接组件后重试';
        });
      }
    } finally {
      await session?.close();
    }
  }

  Future<void> _save() async {
    if (_selectedModel == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    LocalCodingBridgeSession? session;
    try {
      final selection = _selectedModel;
      final expectedUrl = _selectedUrl;
      final expectedModel = _selectedModelId;
      await _refreshModels();
      if (!mounted) return;
      final option = _models
          .where((o) => _optionId(o.provider, o.model) == selection)
          .firstOrNull;
      if (option == null ||
          _modelBaseUrls[option.provider.id] != expectedUrl ||
          option.model.modelId != expectedModel) {
        setState(() {
          _selectedModel = null;
          _error = '模型服务配置已变化，请重新选择模型';
        });
        return;
      }
      final uri = Uri.tryParse(expectedUrl ?? '');
      final local = ['localhost', '127.0.0.1', '::1'].contains(uri?.host);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
        setState(() => _error = '服务商地址无效，请在模型服务中修改');
        return;
      }
      final apiKey =
          await const ModelServiceStore().getApiKey(option.provider.id) ?? '';
      if (apiKey.trim().isEmpty) {
        if (mounted) setState(() => _error = '该服务商未保存 API Key，请先在模型服务中配置');
        return;
      }
      session = await _sessionFactory.open();
      await session.byokSettings(
          target: widget.vendor.cliTarget,
          save: true,
          baseUrl: expectedUrl,
          model: expectedModel,
          apiKey: apiKey);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请检查模型服务和本地配置目录权限后重试');
    } finally {
      await session?.close();
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_saving,
      child: UiContentDialog(
        size: UiDialogSize.standard,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UiSheetHeader(
                  title: '${widget.vendor.displayName} API 设置',
                  subtitle: '从模型服务选择配置，自动使用对应地址和 API Key。',
                  onClose:
                      _saving ? null : () => Navigator.of(context).pop(false),
                ),
                const SizedBox(height: 20),
                if (_loading)
                  const Center(child: CupertinoActivityIndicator())
                else ...[
                  Builder(builder: (anchor) {
                    final selected = _models
                        .where((o) =>
                            _optionId(o.provider, o.model) == _selectedModel)
                        .firstOrNull;
                    return AgentControlButton(
                        key: const ValueKey('api-settings-model-button'),
                        label: selected == null
                            ? '从模型配置选择'
                            : '${selected.provider.name} / ${selected.model.displayName}',
                        icon: CupertinoIcons.sparkles,
                        leading: selected == null
                            ? null
                            : conversationModelIcon(
                                context, selected.model.modelId, size: 22),
                        onPressed:
                            _saving ? null : () => _openModelPicker(anchor));
                  }),
                  const SizedBox(height: 16),
                  if (_selectedModel != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: UiFieldStyle.enabledBorderColor(scheme)),
                      ),
                      child: Table(
                        columnWidths: const {
                          0: FixedColumnWidth(88),
                          1: FlexColumnWidth(),
                        },
                        defaultVerticalAlignment:
                            TableCellVerticalAlignment.top,
                        children: [
                          for (final field in [
                            ('API 地址', _selectedUrl ?? ''),
                            ('模型', _selectedModelId ?? ''),
                          ])
                            TableRow(children: [
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Text(field.$1,
                                    style: TextStyle(
                                        fontSize: 12,
                                        height: 1.5,
                                        color: scheme.onSurfaceVariant)),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Text(field.$2,
                                    style: TextStyle(
                                        fontSize: 12,
                                        height: 1.5,
                                        fontWeight: FontWeight.w500,
                                        color: scheme.onSurface)),
                              ),
                            ]),
                        ],
                      ),
                    )
                  else
                    Text(
                        _models.isEmpty
                            ? '暂无兼容模型，请先在模型服务中配置并启用。'
                            : '请选择模型服务中的模型后保存。',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                        onPressed: _saving ? null : _manageModels,
                        icon: const Icon(CupertinoIcons.gear_alt, size: 14),
                        label: const Text('管理模型服务')),
                  ),
                  const SizedBox(height: 16),
                  Text('保存后点击卡片中的接入或切换按钮应用配置。',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _loading || _saving || _selectedModel == null
                          ? null
                          : _save,
                      child: Text(_saving ? '保存中…' : '保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
