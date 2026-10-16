import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

import '../models/ai_provider_config.dart';
import '../providers/model_service_providers.dart';

const _uuid = Uuid();

/// 「请求配置」：图像生成/编辑 Base URL、自定义请求头。
/// 参考 Cherry Studio 的 `ProviderCustomHeaderDrawer`。落地/保存逻辑通过
/// [ensureLocalId] 交给调用方，与主面板共用同一套"只有真正保存才落地"的规则。
Future<void> showRequestConfigDialog(
  BuildContext context, {
  required AiProviderConfig provider,
  required Future<String> Function() ensureLocalId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RequestConfigDialog(
      provider: provider,
      ensureLocalId: ensureLocalId
    ),
  );
}

class _HeaderRow {
  _HeaderRow({String? key, String? value})
      : id = _uuid.v4(),
        keyController = TextEditingController(text: key ?? ''),
        valueController = TextEditingController(text: value ?? '');

  final String id;
  final TextEditingController keyController;
  final TextEditingController valueController;

  void dispose() {
    keyController.dispose();
    valueController.dispose();
  }
}

class _RequestConfigDialog extends ConsumerStatefulWidget {
  const _RequestConfigDialog({
    required this.provider,
    required this.ensureLocalId,
  });

  final AiProviderConfig provider;
  final Future<String> Function() ensureLocalId;

  @override
  ConsumerState<_RequestConfigDialog> createState() =>
      _RequestConfigDialogState();
}

class _RequestConfigDialogState extends ConsumerState<_RequestConfigDialog> {
  late final TextEditingController _imageGenController;
  late final TextEditingController _imageEditController;
  late List<_HeaderRow> _headerRows;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _imageGenController =
        TextEditingController(text: provider.imageGenerationBaseUrl);
    _imageEditController =
        TextEditingController(text: provider.imageEditBaseUrl);
    _headerRows = [
      for (final entry in provider.customHeaders.entries)
        _HeaderRow(key: entry.key, value: entry.value),
    ];
  }

  @override
  void dispose() {
    _imageGenController.dispose();
    _imageEditController.dispose();
    for (final row in _headerRows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final headers = <String, String>{
      for (final row in _headerRows)
        if (row.keyController.text.trim().isNotEmpty)
          row.keyController.text.trim(): row.valueController.text,
    };

    final id = await widget.ensureLocalId();
    final current = ref.read(modelProvidersProvider).value?.firstWhere(
              (p) => p.id == id,
              orElse: () => widget.provider
            ) ??
        widget.provider;
    await ref.read(modelProvidersProvider.notifier).updateProvider(
          current.copyWith(
            imageGenerationBaseUrl: _imageGenController.text.trim(),
            imageEditBaseUrl: _imageEditController.text.trim(),
            customHeaders: headers,
          ),
        );
    if (!mounted) return;
    setState(() => _saving = false);
    BotToast.showText(text: '请求配置已保存');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return UiContentDialog(
      size: UiDialogSize.standard,
      maxHeight: 680,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSheetHeader(
              title: '请求配置',
              subtitle: '配置图像服务地址与自定义请求头',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '图像生成 Base URL',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    UiInputField(
                      controller: _imageGenController,
                      hintText: 'https://example.com',
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '图像编辑 Base URL',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    UiInputField(
                      controller: _imageEditController,
                      hintText: 'https://example.com',
                    ),
                    const SizedBox(height: 18),
                    Text(
                      '自定义请求头',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    for (final row in _headerRows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: UiInputField(
                                controller: row.keyController,
                                hintText: 'Header 名',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: UiInputField(
                                controller: row.valueController,
                                hintText: 'Header 值',
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(CupertinoIcons.minus_circle,
                                  size: 16),
                              onPressed: () => setState(() {
                                row.dispose();
                                _headerRows = _headerRows
                                    .where((r) => r.id != row.id)
                                    .toList();
                              }),
                            ),
                          ],
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => setState(
                          () => _headerRows = [..._headerRows, _HeaderRow()]),
                      icon: const Icon(CupertinoIcons.add, size: 14),
                      label: const Text('添加请求头'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: Text(_saving ? '保存中…' : '保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
