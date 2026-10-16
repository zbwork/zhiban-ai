import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/widgets/conversation_connection_banner.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';
import 'chat_unread_race_test.dart' show item;

void main() {
  testWidgets('cold loading without spinner fits a scrollable sidebar',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            ConversationListPanel(
              selectedConversationId: null,
              conversations: const [],
              loadingConversations: true,
              showLoadingIndicator: false,
              onConversationSelected: (_) {},
            ),
          ]),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('暂无会话'), findsNothing);
  });

  for (final offline in [false, true]) {
    testWidgets(
        'tenant switch uses inline loading across scopes, offline=$offline',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previous = request.interceptors.toList();
      request.interceptors.clear();
      final started = Completer<void>();
      final release = Completer<void>();
      request.interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) async {
        started.complete();
        await release.future;
        handler.reject(DioException(requestOptions: options));
      }));
      addTearDown(() {
        request.interceptors.clear();
        request.interceptors.addAll(previous);
      });

      Widget page(String scope, {bool initialLoading = false}) => ProviderScope(
            key: ValueKey(scope),
            overrides: [
              conversationsRefreshingProvider.overrideWith((ref) => false),
              conversationConnectionStateProvider.overrideWith((ref) =>
                  Stream.value(ConversationConnectionSnapshot(
                      ConversationConnectionState.connected,
                      offline
                          ? ConversationNetworkState.offline
                          : ConversationNetworkState.available))),
            ],
            child: MaterialApp(
                home: Scaffold(
                    body: Column(children: [
              ConversationConnectionBanner(initialLoading: initialLoading),
              ConversationListPanel(
                selectedConversationId: null,
                conversations: [item(0)],
                loadingConversations: initialLoading,
                showLoadingIndicator: false,
                onConversationSelected: (_) {},
              ),
            ]))),
          );
      await tester.pumpWidget(page('old'));
      await tester.pump();
      expect(find.text('正在加载会话…'), findsNothing);
      expect(find.text('peer'), findsOneWidget);

      final failed =
          expectLater(switchToTenantApi(2), throwsA(isA<DioException>()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(started.isCompleted, true);
      expect(find.text('正在加载会话…'), offline ? findsNothing : findsOneWidget);
      expect(find.text('连不上服务器'), offline ? findsOneWidget : findsNothing);
      expect(find.byType(CupertinoActivityIndicator),
          offline ? findsNothing : findsOneWidget);
      expect(find.text('peer'), findsNothing);
      expect(find.text('暂无会话'), findsNothing);

      // A new session must immediately observe the in-flight switch lock.
      await tester.pumpWidget(page('new'));
      await tester.pump();
      expect(find.text('peer'), findsNothing);
      expect(find.text('正在加载会话…'), offline ? findsNothing : findsOneWidget);
      await tester.pumpWidget(page('new', initialLoading: true));
      release.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await failed;
      await tester.pump();
      expect(tenantSwitchInProgress.value, false);
      expect(find.text('peer'), findsOneWidget,
          reason: 'A rejected switch restores the original tenant list');
      // The list's cold loading takes over without hiding the inline row.
      expect(find.text('正在加载会话…'), offline ? findsNothing : findsOneWidget);
      await tester.pumpWidget(page('new'));
      await tester.pump();
      expect(find.text('正在加载会话…'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });
  }

  for (final offline in [false, true]) {
    testWidgets('loading shares banner with offline priority=$offline',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            conversationsRefreshingProvider.overrideWith((ref) => true),
            conversationConnectionStateProvider.overrideWith((ref) =>
                Stream.value(ConversationConnectionSnapshot(
                    ConversationConnectionState.connecting,
                    offline
                        ? ConversationNetworkState.offline
                        : ConversationNetworkState.available))),
          ],
          child: const MaterialApp(
              home: Scaffold(body: ConversationConnectionBanner()))));
      await tester.pump();
      expect(find.text('正在加载会话…'), offline ? findsNothing : findsOneWidget);
      expect(find.text('连不上服务器'), offline ? findsOneWidget : findsNothing);
    });
  }

  for (final connection in ConversationConnectionState.values) {
    for (final network in ConversationNetworkState.values) {
      testWidgets('banner $connection / $network', (tester) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            conversationsRefreshingProvider.overrideWith((ref) => false),
            conversationConnectionStateProvider.overrideWith((ref) =>
                Stream.value(
                    ConversationConnectionSnapshot(connection, network))),
          ],
          child: const MaterialApp(
              home: Scaffold(
                  body: Column(children: [
            Text('搜索'),
            ConversationConnectionBanner(),
            Text('已有会话'),
          ]))),
        ));
        await tester.pump();
        expect(
            find.text('连不上服务器'),
            network == ConversationNetworkState.offline
                ? findsOneWidget
                : findsNothing);
        expect(find.text('已有会话'), findsOneWidget);
        if (network == ConversationNetworkState.offline) {
          expect(tester.getTopLeft(find.text('连不上服务器')).dy,
              lessThan(tester.getTopLeft(find.text('已有会话')).dy));
        }
      });
    }
  }
}
