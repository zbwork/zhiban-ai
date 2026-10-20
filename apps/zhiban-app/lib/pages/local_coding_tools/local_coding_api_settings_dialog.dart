import 'package:flutter/material.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

Future<bool?> showLocalCodingApiSettings(
  BuildContext context,
  LocalCodingVendor vendor,
) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _ApiSettings(vendor: vendor),
    );

class _ApiSettings extends StatefulWidget {
  const _ApiSettings({required this.vendor});
  final LocalCodingVendor vendor;
  @override
  State<_ApiSettings> createState() => _ApiSettingsState();
}

class _ApiSettingsState extends State<_ApiSettings> {
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _keyConfigured = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    LocalCodingBridgeSession? session;
    try {
      session = await ProcessLocalCodingBridgeSessionFactory().open();
      final info = await session.byokSettings(target: widget.vendor.cliTarget);
      if (!mounted) return;
      _url.text = info['base_url'] as String? ?? '';
      _model.text = info['model'] as String? ?? '';
      setState(() {
        _keyConfigured = info['key_configured'] == true;
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
    final uri = Uri.tryParse(_url.text.trim());
    final local = uri?.host == 'localhost' ||
        uri?.host == '127.0.0.1' ||
        uri?.host == '::1';
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) ||
        _model.text.trim().isEmpty ||
        (!_keyConfigured && _key.text.isEmpty)) {
      setState(() => _error = '请填写有效的 HTTPS API 地址、模型和 API Key（本机地址可使用 HTTP）');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    LocalCodingBridgeSession? session;
    try {
      session = await ProcessLocalCodingBridgeSessionFactory().open();
      await session.byokSettings(
        target: widget.vendor.cliTarget,
        save: true,
        baseUrl: _url.text.trim(),
        model: _model.text.trim(),
        apiKey: _key.text,
      );
      _key.clear();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请检查地址、模型和本机安全凭据库后重试');
    } finally {
      await session?.close();
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.clear();
    _key.dispose();
    super.dispose();
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
                  subtitle: '使用你自己的模型服务，API Key 仅保存在本机安全凭据库。',
                  onClose:
                      _saving ? null : () => Navigator.of(context).pop(false),
                ),
                const SizedBox(height: 20),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  UiInputField(
                    label: 'API 地址',
                    controller: _url,
                    enabled: !_saving,
                    hintText: widget.vendor == LocalCodingVendor.codex
                        ? 'https://api.example.com/v1'
                        : 'https://api.example.com',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.vendor == LocalCodingVendor.codex
                        ? '需支持 OpenAI Responses API'
                        : '需支持 Anthropic Messages API',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  UiInputField(
                    label: '模型',
                    controller: _model,
                    enabled: !_saving,
                    hintText: '填写服务商提供的模型名称',
                  ),
                  const SizedBox(height: 12),
                  UiInputField(
                    label: 'API Key',
                    controller: _key,
                    enabled: !_saving,
                    obscureText: true,
                    hintText: _keyConfigured ? '已保存，留空保留原 Key' : '填写你的 API Key',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '保存后点击卡片中的接入或切换按钮应用配置，检测会向你填写的服务发送请求。',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
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
                      onPressed: _loading || _saving ? null : _save,
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
