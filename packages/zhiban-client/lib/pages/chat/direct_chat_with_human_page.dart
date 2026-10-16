import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';

class DirectChatWithHumanPage extends ConsumerStatefulWidget {
  const DirectChatWithHumanPage({
    super.key,
    required this.peerAccountUuid,
    this.title,
  });

  final String peerAccountUuid;
  final String? title;

  @override
  ConsumerState<DirectChatWithHumanPage> createState() =>
      _DirectChatWithHumanPageState();
}

class _DirectChatWithHumanPageState
    extends ConsumerState<DirectChatWithHumanPage> {
  // ADR-0026: 走 ImClient(WuKong)substrate。UI 仅依赖 im_client.dart 抽象。
  late final HumanDirectImController controller;
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    controller = HumanDirectImController(peerAccountUuid: widget.peerAccountUuid);
    controller.addListener(_onChange);
    // ignore: discarded_futures
    controller.open(title: widget.title);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_onChange);
    controller.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.sendText(text);
      _input.clear();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('发送失败: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.title ?? '同事对话';
    return Scaffold(
      appBar: UiPageBar(title: title),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.error != null)
              Container(
                width: double.infinity,
                color: theme.colorScheme.errorContainer,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  '加载失败: ${controller.error}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: controller.loading && controller.messages.isEmpty
                  ? const Center(child: CupertinoActivityIndicator())
                  : ListView.builder(
                      itemCount: controller.messages.length,
                      itemBuilder: (context, i) => _HumanMessageBubble(
                        msg: controller.messages[i],
                        myUid: controller.myUid ?? '',
                      ),
                    ),
            ),
            _buildInputBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              controller: _input,
              placeholder: '给同事发消息...',
              minLines: 1,
              maxLines: 4,
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CupertinoActivityIndicator(),
                  )
                : const Text('发送'),
          ),
        ],
      ),
    );
  }
}

class _HumanMessageBubble extends StatelessWidget {
  const _HumanMessageBubble({
    required this.msg,
    required this.myUid
  });

  final ImMessage msg;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPeer = msg.fromUid != myUid;
    final align = isPeer ? CrossAxisAlignment.start : CrossAxisAlignment.end;
    final bg = isPeer
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.primaryContainer;
    final fg = isPeer
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              msg.text.isNotEmpty ? msg.text : '[非文本消息]',
              style: TextStyle(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}
