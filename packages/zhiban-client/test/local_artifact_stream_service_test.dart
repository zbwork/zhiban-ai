import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';

class ArtifactStreamAdapter implements HttpClientAdapter {
  final stream = StreamController<Uint8List>();
  final requested = Completer<void>();
  void send(Map<String, dynamic> event) => stream
      .add(Uint8List.fromList(utf8.encode('data: ${jsonEncode(event)}\n\n')));
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body,
      Future<void>? cancelFuture) async {
    requested.complete();
    return ResponseBody(stream.stream, 200, headers: {
      Headers.contentTypeHeader: ['text/event-stream']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('SSE 在终态前透传本机卡片，保持累计文本与消息身份', () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = ArtifactStreamAdapter();
    final old = request.httpClientAdapter;
    request.httpClientAdapter = adapter;
    addTearDown(() => request.httpClientAdapter = old);
    final seen = <Map<String, dynamic>>[];
    final appeared = Completer<void>();
    var done = false;
    final work = OpenClawChatService().streamMessage(
        streamId: 's',
        onEvent: (event) async {
          seen.add(event);
          if (event['eventType'] == 'local_artifacts' && !appeared.isCompleted) {
            appeared.complete();
          }
        },
        onDone: () async {
          done = true;
        });
    await adapter.requested.future;
    const card = {
      'type': 'image',
      'name': 'poster.png',
      'mime': 'image/png',
      'size': 100,
      'local_artifact': {'artifact_id': 'a', 'device_id': 'd', 'sha256': 'hash'}
    };
    adapter.send({
      'kind': 'message.block.delta',
      'stream_id': 's',
      'conversation_uuid': 'c',
      'message_uuid': 'm',
      'local_artifacts': true,
      'blocks': [card]
    });
    await appeared.future.timeout(const Duration(seconds: 3));
    expect(done, isFalse);
    expect(seen.single['blocks'], [card]);
    expect(seen.single['message_uuid'], 'm');
    adapter.send({'kind': 'message.block.delta', 'text': '继续'});
    adapter.send({'kind': 'message.block.delta', 'text': '继续生成'});
    adapter.send({
      'kind': 'message.completed',
      'text': '完成',
      'blocks': [card]
    });
    await adapter.stream.close();
    await work;
    expect(
        seen
            .where((e) => e['eventType'] == 'message' && e['finished'] == false)
            .map((e) => e['content'])
            .toList(),
        ['继续', '生成']);
    expect(done, isTrue);
  });
}
