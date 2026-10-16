import 'package:dio/dio.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold offline cache remains visible and resumes sync on connection',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = _ColdClient();
    final controller = HumanDirectImController(
      presetChannelId: 'direct-channel',
      presetChannelType: 2,
      presetConversationUuid: 'conversation-1',
      client: client,
      credentials: _OfflineCredentials(),
    );
    addTearDown(() async {
      controller.dispose();
      await client.dispose();
    });
    await controller.open();
    expect(controller.loading, isFalse);
    expect(controller.messages.single.text, '账号 A 发出的旧消息');
    expect(client.connectedUid, isNull);
    client.online = true;
    client.statuses.add(ImConnectionStatus.connected);
    await _waitUntil(() => controller.messages.length == 2);
    expect(controller.messages.last.text, '账号 B 在 A 退出后回复');
    expect(client.latestSyncCalls, 1);
  });

  test('cached direct history reconciles messages received while logged out',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = _OfflineTailImClient();
    final controller = HumanDirectImController(
      presetChannelId: 'direct-channel',
      presetChannelType: 2,
      presetConversationUuid: 'conversation-1',
      client: client,
    );
    addTearDown(controller.dispose);

    await controller.open();

    expect(controller.messages.map((message) => message.text),
        contains('账号 A 发出的旧消息'));
    await _waitUntil(() => client.latestSyncCalls == 1);
    await _waitUntil(() => controller.messages.length == 2);
    expect(
      controller.messages.map((message) => message.text),
      ['账号 A 发出的旧消息', '账号 B 在 A 退出后回复']
    );
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _OfflineTailImClient implements ImClient, ImLatestHistorySyncClient {
  final _messages = StreamController<ImMessage>.broadcast();
  int latestSyncCalls = 0;

  static const _cached = ImMessage(
    messageId: '1',
    clientMsgNo: 'client-1',
    fromUid: 'account-a',
    channelId: 'direct-channel',
    channelType: 2,
    timestamp: 1,
    text: '账号 A 发出的旧消息',
    messageSeq: 1,
  );
  static const _offlineReply = ImMessage(
    messageId: '2',
    clientMsgNo: 'client-2',
    fromUid: 'account-b',
    channelId: 'direct-channel',
    channelType: 2,
    timestamp: 2,
    text: '账号 B 在 A 退出后回复',
    messageSeq: 2,
  );

  @override
  String? get connectedUid => 'account-a';

  @override
  ImConnectionStatus get connectionStatus => ImConnectionStatus.connected;

  @override
  bool get isRealtimeConnected => true;

  @override
  Future<List<ImMessage>> getHistoryMessages(
    String channelId,
    int channelType, {
    int limit = 30,
    int beforeMessageSeq = 0,
    String? conversationUuid,
    String? clearedAt,
  }) async =>
      const [_cached];

  @override
  Future<List<ImMessage>> syncLatestHistoryMessages(
    String channelId,
    int channelType, {
    int limit = 30,
    String? conversationUuid,
    String? clearedAt,
  }) async {
    latestSyncCalls++;
    return const [_cached, _offlineReply];
  }

  @override
  Stream<ImMessage> listenMessages() => _messages.stream;

  @override
  Stream<ImConnectionStatus> listenConnectionStatus() => const Stream.empty();

  @override
  Stream<ImConversationEvent> listenConversationEvents() =>
      const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _messages.close();
  }

  @override
  Future<List<ImConversation>> getConversationList() async => const [];

  @override
  Future<void> init() async {}

  @override
  Future<void> login(ImConnInfo info) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> markRead(String channelId, int channelType) async {}

  @override
  Future<void> sendFileMessage(
    String channelId,
    int channelType, {
    required String url,
    required String fileUuid,
    required String refUuid,
    required String name,
    int size = 0,
    String mime = '',
  }) async {}

  @override
  Future<void> sendImageMessage(
    String channelId,
    int channelType, {
    required String url,
    required String fileUuid,
    String refUuid = '',
    String name = '',
    int width = 0,
    int height = 0,
  }) async {}

  @override
  Future<void> sendMixedMessage(
    String channelId,
    int channelType, {
    required List<ImMessageBlock> blocks,
    String summary = '',
    List<Map<String, dynamic>>? mentions,
    Map<String, dynamic>? reply,
  }) async {}

  @override
  Future<void> sendTextMessage(
    String channelId,
    int channelType,
    String text, {
    List<Map<String, dynamic>>? mentions,
  }) async {}

  @override
  Future<int> unreadCount() async => 0;
}

class _ColdClient extends _OfflineTailImClient implements ImLocalHistoryClient {
  bool online = false;
  final statuses = StreamController<ImConnectionStatus>.broadcast();
  @override
  String? get connectedUid => online ? 'account-a' : null;
  @override
  ImConnectionStatus get connectionStatus =>
      online ? ImConnectionStatus.connected : ImConnectionStatus.idle;
  @override
  bool get isRealtimeConnected => online;
  @override
  Stream<ImConnectionStatus> listenConnectionStatus() => statuses.stream;
  @override
  Future<ImLocalHistory?> readLocalHistory(String channelId, int channelType,
          {int limit = 40}) async =>
      (uid: 'account-a', messages: [_OfflineTailImClient._cached]);
  @override
  Future<void> dispose() async {
    await statuses.close();
    await super.dispose();
  }
}

class _OfflineCredentials extends IMCredentialsClient {
  @override
  Future<ImConnInfo> fetchWukongConnInfo() async => throw DioException(
      requestOptions: RequestOptions(path: '/im/credentials'),
      type: DioExceptionType.connectionError);
}
