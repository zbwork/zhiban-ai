import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:zhiban_client/services/app_notification_service.dart';
import 'session_bootstrap_providers.dart';

class SessionLayout extends ConsumerStatefulWidget {
  const SessionLayout({super.key, required this.builder});
  final Widget Function(BuildContext, int) builder;
  @override
  ConsumerState<SessionLayout> createState() => _SessionLayoutState();
}

class _SessionLayoutState extends ConsumerState<SessionLayout>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AppNotificationService.init());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      ref.read(conversationRealtimeBridgeProvider).onAppBackgrounded();
    }
    if (state == AppLifecycleState.resumed) {
      ref.read(conversationRealtimeBridgeProvider).onAppResumed();
      unawaited(AppNotificationService.clearAll());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(managedModelAutoSetupProvider);
    ref.watch(sessionPrewarmBootstrapProvider);
    ref.watch(sessionRealtimeBootstrapProvider);
    ref.watch(localCodingMaintenanceBootstrapProvider);
    ref.watch(sessionLocalAgentBootstrapProvider);

    return widget.builder(context, _chatUnreadCount());
  }

  int _chatUnreadCount() {
    final conversations = ref.watch(conversationsProvider).asData?.value;
    if (conversations == null) return 0;
    var total = 0;
    for (final c in conversations) {
      if (!c.muted) total += c.unreadCount;
    }
    return total;
  }
}
