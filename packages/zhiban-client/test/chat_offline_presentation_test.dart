import 'dart:typed_data';
import 'dart:async';
import 'package:pull_to_refresh/pull_to_refresh.dart';
import 'package:zhiban_client/widgets/ui/ui_pull_to_refresh.dart';
import 'package:zhiban_client/network/user_refresh.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/network/interceptor/response_interceptor.dart';
import 'package:zhiban_client/services/analytics_service.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';

class _OfflineAdapter implements HttpClientAdapter {
  _OfflineAdapter(this.type);
  final DioExceptionType type;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    throw DioException(requestOptions: options, type: type);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('unknown background failure remains reportable', () {
    expect(
        isReportableApiError(DioException(
          requestOptions: RequestOptions(path: '/chat/conversations'),
          type: DioExceptionType.unknown,
        )),
        isTrue);
  });
  testWidgets('first page request is silent', (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: BotToastInit(),
      home: const Scaffold(body: Text('设置')),
    ));
    final dio = Dio()
      ..httpClientAdapter = _OfflineAdapter(DioExceptionType.connectionError)
      ..interceptors.add(ResponseInterceptor());
    addTearDown(dio.close);
    await tester.runAsync(() async {
      await expectLater(
          dio.get<void>('/settings'), throwsA(isA<DioException>()));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法连接到服务器，请检查网络设置'), findsNothing);
    BotToast.cleanAll();
    await tester.pumpAndSettle();
  });
  testWidgets(
      'real pull-to-refresh callback enables toast and completed scope expires',
      (tester) async {
    final dio = Dio()
      ..httpClientAdapter = _OfflineAdapter(DioExceptionType.connectionError)
      ..interceptors.add(ResponseInterceptor());
    final controller = RefreshController();
    addTearDown(dio.close);
    addTearDown(controller.dispose);
    late Completer<void> done;
    await tester.pumpWidget(MaterialApp(
        builder: BotToastInit(),
        home: Scaffold(
          body: UiPullToRefresh(
              controller: controller,
              onRefresh: () async {
                try {
                  await dio.get<void>('/settings');
                } catch (_) {}
                controller.refreshCompleted();
                done.complete();
              },
              child: ListView(children: const [Text('现有内容')])),
        )));
    await tester.runAsync(() async {
      done = Completer<void>();
      tester.widget<SmartRefresher>(find.byType(SmartRefresher)).onRefresh!();
      await done.future;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法连接到服务器，请检查网络设置'), findsOneWidget);
    BotToast.cleanAll();
    await tester.pump(const Duration(seconds: 1));
    late Future<void> Function() delayed;
    await tester.runAsync(() async {
      await UserRefresh.run(() async {
        delayed = Zone.current.bindCallback(() async {
          try {
            await dio.get<void>('/background');
          } catch (_) {}
        });
      });
      await delayed();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法连接到服务器，请检查网络设置'), findsNothing);
  });
  for (final method in ['GET', 'POST']) {
    testWidgets(
        'explicit refresh $method reports once, concurrent automatic stays silent',
        (tester) async {
      await tester.pumpWidget(
          MaterialApp(builder: BotToastInit(), home: const Scaffold()));
      final dio = Dio()
        ..httpClientAdapter = _OfflineAdapter(DioExceptionType.unknown)
        ..interceptors.add(ResponseInterceptor());
      addTearDown(dio.close);
      Future<void> fail() async {
        await expectLater(
            dio.request<void>('/drive:bootstrap',
                options: Options(method: method)),
            throwsA(isA<DioException>()));
      }

      await tester.runAsync(() async {
        await fail();
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('网络异常，请稍后重试'), findsNothing);
      await tester.runAsync(() async {
        await Future.wait([
          UserRefresh.run(() async {
            await fail();
            await fail();
          }),
          fail(),
        ]);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('网络异常，请稍后重试'), findsOneWidget);
      BotToast.cleanAll();
      await tester.pumpAndSettle();
    });
  }
  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.unknown,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.cancel,
    DioExceptionType.badCertificate,
  ]) {
    testWidgets('automatic $type propagates failure without global toast',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        builder: BotToastInit(),
        home: const Scaffold(body: Text('当前聊天')),
      ));
      final dio = Dio()
        ..httpClientAdapter = _OfflineAdapter(type)
        ..interceptors.add(ResponseInterceptor());
      addTearDown(dio.close);
      await tester.runAsync(() async {
        await expectLater(
            dio.get<void>('/chat/conversations', options: Options()),
            throwsA(isA<DioException>().having((e) => e.type, 'type', type)));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('当前聊天'), findsOneWidget);
      expect(find.textContaining('请检查网络'), findsNothing);
      expect(find.text('请求已取消'), findsNothing);
    });
  }

  testWidgets('offline refresh keeps existing conversation row',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      home: Scaffold(
        body: ConversationListPanel(
          selectedConversationId: 'c',
          conversations: const [
            ConversationItem(
              conversationId: 'c',
              title: '已有会话',
              agentId: '',
              agentName: '',
              kind: 'human_direct',
            ),
          ],
          loadingConversations: false,
          onConversationSelected: (_) {},
        ),
      ),
    )));
    expect(find.text('已有会话'), findsOneWidget);
    expect(find.textContaining('加载会话失败'), findsNothing);
    expect(find.textContaining('DioException'), findsNothing);
  });
}
