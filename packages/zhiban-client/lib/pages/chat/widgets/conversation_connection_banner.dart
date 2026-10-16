import 'package:flutter/cupertino.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';

final conversationConnectionUnavailableProvider =
    Provider<AsyncValue<bool>>((ref) {
  return ref
      .watch(conversationConnectionStateProvider)
      .whenData((snapshot) => snapshot.isUnavailable);
});

/// One fixed status row above conversations; never covers the message pane.
class ConversationConnectionBanner extends ConsumerWidget {
  const ConversationConnectionBanner({super.key, this.initialLoading = false});

  final bool initialLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline =
        ref.watch(conversationConnectionStateProvider).value?.isOffline == true;
    final refreshing = ref.watch(conversationsRefreshingProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: tenantSwitchInProgress,
      builder: (context, switching, _) {
        final loading = initialLoading || refreshing || switching;
        if (!offline && !loading) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        return Semantics(
          liveRegion: true,
          child: Container(
            width: double.infinity,
            color: (offline
                    ? scheme.errorContainer
                    : scheme.surfaceContainerHighest)
                .withValues(alpha: 0.35),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              if (offline)
                Icon(Icons.link_off, color: scheme.error, size: 19)
              else
                const CupertinoActivityIndicator(radius: 9),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(offline ? '连不上服务器' : '正在加载会话…',
                      style: TextStyle(
                          color:
                              offline ? scheme.error : scheme.onSurfaceVariant,
                          fontSize: 14))),
            ]),
          ),
        );
      },
    );
  }
}
