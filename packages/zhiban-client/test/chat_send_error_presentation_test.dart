import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/network/interceptor/response_interceptor.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';

void main() {
  final service = OpenClawChatService();
  final sends = <String, Future<Object?> Function()>{
    'chat send': () => service.sendMessage(agentUuid: 'agent', prompt: 'test'),
    'room send': () =>
        service.sendRoomMessage(roomUuid: 'room', prompt: 'test'),
    'prepare': () => service.prepareAgentDirectWuKong('agent'),
    'attach': () => service.attachAgentDirectStream(
          conversationUuid: 'conversation',
          wukongChannelId: 'channel',
          wukongMessageId: 'message',
        ),
  };
  for (final entry in sends.entries) {
    for (final failure in ['business', 'server', 'offline']) {
      testWidgets('${entry.key}: $failure propagates without toast',
          (tester) async {
        final original = request.interceptors.toList();
        request.interceptors.clear();
        addTearDown(() {
          request.interceptors.clear();
          request.interceptors.addAll(original);
        });
        RequestOptions? sent;
        request.interceptors
            .add(InterceptorsWrapper(onRequest: (options, handler) {
          sent = options;
          final response = Response<dynamic>(
            requestOptions: options,
            statusCode: failure == 'business' ? 400 : 503,
            data: {'success': false, 'code': 4000, 'message': '发送失败，请稍后重试'},
          );
          if (failure == 'business') {
            handler.resolve(response, true);
          } else {
            handler.reject(
                DioException(
                  requestOptions: options,
                  response: failure == 'server' ? response : null,
                  type: failure == 'server'
                      ? DioExceptionType.badResponse
                      : DioExceptionType.connectionError,
                ),
                true);
          }
        }));
        request.interceptors.add(ResponseInterceptor());
        await tester.pumpWidget(MaterialApp(
          builder: BotToastInit(),
          home: const Scaffold(body: Text('conversation')),
        ));
        await tester.runAsync(() async {
          await expectLater(entry.value(), throwsA(isA<DioException>()));
        });
        await tester.pump();
        expect(sent?.extra['silent'], true);
        expect(find.text('发送失败，请稍后重试'), findsNothing);
        expect(find.text('无法连接到服务器，请检查网络设置'), findsNothing);
        expect(find.text('服务器繁忙，请稍后重试'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
