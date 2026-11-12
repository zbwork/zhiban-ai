import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import '../../services/server_connection.dart';

Future<void> openServerConnectionGuide() async {
  try {
    if (await launchUrl(
      Uri.parse('https://github.com/zbwork/zhiban-ai#readme'),
      mode: LaunchMode.externalApplication,
    )) {
      return;
    }
  } catch (_) {
    // Keep the current workspace and form draft available.
  }
  BotToast.showText(text: '无法打开 GitHub README，请稍后重试');
}

Future<String?> showServerConnectionDialog(BuildContext context) async {
  final saved = await ServerConnection.savedAddress();
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ServerConnectionDialog(initialAddress: saved),
  );
}

class ServerConnectionDialog extends StatefulWidget {
  const ServerConnectionDialog({super.key, this.initialAddress, this.probe});
  final String? initialAddress;
  final Future<String> Function(String)? probe;

  @override
  State<ServerConnectionDialog> createState() => _ServerConnectionDialogState();
}

class _ServerConnectionDialogState extends State<ServerConnectionDialog> {
  late final _address =
      TextEditingController(text: widget.initialAddress ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final address =
          await (widget.probe ?? ServerConnection.probe)(_address.text);
      if (!mounted) return;
      await ServerConnection.save(address);
      if (mounted) Navigator.of(context).pop(address);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error =
              error is FormatException ? error.message : '连接失败，请检查服务器地址后重试';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UiSheetHeader(
                  title: '连接服务器',
                  subtitle: '连接团队或自己部署的知办AI服务',
                  onClose: () => Navigator.of(context).pop(),
                  closeEnabled: !_busy,
                ),
                const SizedBox(height: 24),
                UiInputField(
                  label: '服务器地址',
                  controller: _address,
                  hintText: 'https://ai.example.com',
                  autofocus: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  errorText: _error,
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 12),
                Text(
                  '填写服务器根地址，或完整 Bus API 地址。HTTP 仅用于本机、局域网调试。',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '连接后使用服务器账号登录。本地员工、聊天和模型密钥保留在这台设备，不会自动上传。可随时返回本地工作区。',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 24),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton.icon(
                    onPressed: openServerConnectionGuide,
                    icon: const Icon(CupertinoIcons.question_circle, size: 16),
                    label: const Text('接入指南'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: _busy
                        ? const Row(mainAxisSize: MainAxisSize.min, children: [
                            CupertinoActivityIndicator(radius: 8),
                            SizedBox(width: 8),
                            Text('正在检测'),
                          ])
                        : const Text('检测并连接'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
