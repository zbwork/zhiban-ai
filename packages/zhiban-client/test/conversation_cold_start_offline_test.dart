import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_unread_race_test.dart' show EmptyCatalog, item;

class OfflineService extends OpenClawChatService {
  bool offline = true;
  int calls = 0;
  @override
  Future<List<AgentItem>> listAgents() async => [];
  @override
  Future<List<ConversationItem>> listAllConversations({
    int page = 1,
    int pageSize = 40,
    bool includeHidden = false,
  }) async {
    calls++;
    if (offline) {
      throw DioException(
          requestOptions: RequestOptions(path: '/chat/conversations'),
          type: DioExceptionType.connectionError);
    }
    return [item(0)];
  }
}

class CachedService extends OfflineService {
  CachedService(this.cached);
  final List<ConversationItem> cached;
  Completer<List<ConversationItem>> pending = Completer();
  @override
  Future<List<ConversationItem>?> getCachedConversations() async => cached;
  @override
  Future<List<ConversationItem>> listAllConversations(
      {int page = 1, int pageSize = 40, bool includeHidden = false}) {
    calls++;
    return pending.future;
  }
}

void main() {
  testWidgets(
      'desktop list renders cached rows while cold-start network stays pending',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = CachedService([item(2)]);
    final c = ProviderContainer(overrides: [
      chatServiceProvider.overrideWithValue(svc),
      digitalEmployeeCatalogProvider.overrideWith(EmptyCatalog.new),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 240,
        child: Consumer(builder: (context, ref, _) {
          final data = ref.watch(conversationsProvider);
          return ConversationListPanel(
            selectedConversationId: null,
            conversations: data.asData?.value ?? [],
            loadingConversations: data.isLoading,
            onConversationSelected: (_) {},
          );
        }),
      ))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(svc.calls, 1);
    expect(svc.pending.isCompleted, false);
    expect(find.text('peer'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(c.read(conversationsRefreshingProvider), true);
    svc.pending.completeError(DioException(
        requestOptions: RequestOptions(path: '/chat/conversations'),
        type: DioExceptionType.connectionError));
    await tester.pump();
    expect(find.text('peer'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final empty in [false, true]) {
    testWidgets(
        'cold start serves cached ${empty ? 'empty list' : 'conversations'} before network, offline refresh retains it',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final svc = CachedService(empty ? [] : [item(2)]);
      final c = ProviderContainer(overrides: [
        chatServiceProvider.overrideWithValue(svc),
        digitalEmployeeCatalogProvider.overrideWith(EmptyCatalog.new),
      ]);
      addTearDown(c.dispose);
      bool? refreshingAtFirstData;
      c.listen(conversationsProvider, (_, next) {
        if (next.hasValue) {
          refreshingAtFirstData ??= c.read(conversationsRefreshingProvider);
        }
      });
      await tester.pump();
      await tester.pump();
      expect(c.read(conversationsProvider).isLoading, false);
      expect(refreshingAtFirstData, true,
          reason: 'Publishing cached data must not leave a gap in loading');
      expect(c.read(conversationsProvider).requireValue.length, empty ? 0 : 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(svc.calls, 1);
      expect(c.read(conversationsRefreshingProvider), true);
      svc.pending.completeError(DioException(
          requestOptions: RequestOptions(path: '/chat/conversations'),
          type: DioExceptionType.connectionError));
      await tester.pump();
      expect(c.read(conversationsProvider).requireValue.length, empty ? 0 : 1);
      svc.pending = Completer();
      final refreshing =
          c.read(conversationsProvider.notifier).refresh(showLoading: false);
      expect(c.read(conversationsRefreshingProvider), empty);
      svc.pending.complete([item(7)]);
      await refreshing;
      expect(c.read(conversationsProvider).requireValue.single.unreadCount, 7);
      expect(c.read(conversationsRefreshingProvider), false);
      await tester.pump();
    });
  }

  testWidgets(
      'cold offline failure ends loading, does not retry, reconnect refresh recovers',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = OfflineService();
    final container = ProviderContainer(overrides: [
      chatServiceProvider.overrideWithValue(service),
      digitalEmployeeCatalogProvider.overrideWith(EmptyCatalog.new),
    ]);
    addTearDown(container.dispose);
    container.listen(conversationsProvider, (_, __) {});
    await tester.pump();
    expect(container.read(conversationsProvider).isLoading, false);
    expect(container.read(conversationsProvider).hasError, true);
    await tester.pump(const Duration(seconds: 30));
    expect(service.calls, 1);
    service.offline = false;
    await container.read(conversationsProvider.notifier).refresh();
    expect(
        container
            .read(conversationsProvider)
            .requireValue
            .single
            .conversationId,
        'c');
  });
}
