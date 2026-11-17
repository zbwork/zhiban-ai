import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

/// A required step before a provisioned account can access server business APIs.
class InitialPasswordPage extends StatefulWidget {
  const InitialPasswordPage({super.key, this.onSave});
  final Future<void> Function(String)? onSave;

  @override
  State<InitialPasswordPage> createState() => _InitialPasswordPageState();
}

class _InitialPasswordPageState extends State<InitialPasswordPage> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_password.text.length < 8) {
      setState(() => _error = '新密码长度至少 8 位');
      return;
    }
    if (_password.text != _confirmation.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.onSave ?? setInitialPasswordApi)(_password.text);
      _password.clear();
      _confirmation.clear();
      if (!mounted) return;
      BotToast.showText(text: '密码已设置，请使用新密码登录');
      context.go(RoutePaths.login);
    } catch (e) {
      if (mounted) setState(() => _error = formatError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('设置你的密码', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text('这是你首次登录。请设置自己的密码后，再进入服务器工作区。',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            UiInputField(
                controller: _password,
                hintText: '新密码（至少 8 位）',
                obscureText: true,
                enabled: !_busy,
                autofillHints: const [AutofillHints.newPassword]),
            const SizedBox(height: 16),
            UiInputField(
                controller: _confirmation,
                hintText: '再次输入新密码',
                obscureText: true,
                enabled: !_busy,
                onSubmitted: _busy ? null : (_) => _save()),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: scheme.error))),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const CupertinoActivityIndicator()
                    : const Text('设置密码并重新登录')),
          ]),
        ),
      ))),
    );
  }
}
