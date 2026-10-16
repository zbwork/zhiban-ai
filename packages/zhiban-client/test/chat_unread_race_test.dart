import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

ConversationItem item(int unread) => ConversationItem(
    conversationId: 'c',
    title: 'peer',
    agentId: '',
    agentName: '',
    kind: 'human_direct',
    wukongChannelId: 'channel',
    wukongChannelType: 2,
    unreadCount: unread);

class HoldingService extends OpenClawChatService {
  final requests = <Completer<List<ConversationItem>>>[];
  bool hold = false;
  @override
  Future<List<ConversationItem>> listAllConversations(
      {int page = 1, int pageSize = 40, bool includeHidden = false}) {
    if (!hold) return Future.value([item(3)]);
    final pending = Completer<List<ConversationItem>>();
    requests.add(pending);
    return pending.future;
  }

  @override
  Future<List<AgentItem>> listAgents() async => [];
}

class EmptyCatalog extends DigitalEmployeeCatalogNotifier {
  @override
  Future<DigitalEmployeeCatalog> build() async =>
      const DigitalEmployeeCatalog(personal: [], enterprise: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HoldingService svc;
  late ProviderContainer c;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    svc = HoldingService();
    c = ProviderContainer(overrides: [
      chatServiceProvider.overrideWithValue(svc),
      digitalEmployeeCatalogProvider.overrideWith(EmptyCatalog.new)
    ]);
    await c.read(conversationsProvider.future);
    svc.hold = true;
  });
  tearDown(() => c.dispose());
  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.unknown,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    test('$type preserves latest list and recovers on next refresh', () async {
      final n = c.read(conversationsProvider.notifier);
      final pending = n.refresh();
      n.clearUnreadLocally('c');
      svc.requests.last.completeError(DioException(
        requestOptions: RequestOptions(path: '/chat/conversations'),
        type: type,
      ));
      await pending;
      expect(c.read(conversationsProvider).hasError, isFalse);
      expect(c.read(conversationsProvider).requireValue.single.unreadCount, 0);
      final recovered = n.refresh();
      svc.requests.last.complete([item(2)]);
      await recovered;
      expect(c.read(conversationsProvider).requireValue.single.unreadCount, 2);
    });
  }
  test('permission failure is not treated as offline cached success', () async {
    final pending = c.read(conversationsProvider.notifier).refresh();
    final options = RequestOptions(path: '/chat/conversations');
    svc.requests.last.completeError(DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: options, statusCode: 403),
    ));
    await pending;
    expect(c.read(conversationsProvider).hasError, isTrue);
  });
  test('older list response cannot restore locally cleared unread', () async {
    final n = c.read(conversationsProvider.notifier);
    final pending = n.refresh();
    n.clearUnreadLocally('c');
    svc.requests.last.complete([item(3)]);
    await pending;
    expect(c.read(conversationsProvider).requireValue.single.unreadCount, 0);
    final later = n.refresh();
    svc.requests.last.complete([item(2)]);
    await later;
    expect(c.read(conversationsProvider).requireValue.single.unreadCount, 2);
  });
  test('new message arriving during refresh is not erased', () async {
    final n = c.read(conversationsProvider.notifier);
    n.clearUnreadLocally('c');
    final pending = n.refresh();
    n.applyRealtimeMessage(
        channelId: 'channel',
        channelType: 2,
        previewText: 'new',
        fromSelf: false,
        currentConversationIds: {});
    svc.requests.last.complete([item(0)]);
    await pending;
    expect(c.read(conversationsProvider).requireValue.single.unreadCount, 1);
  });
  test('out-of-order refresh responses cannot replace newest server state',
      () async {
    final n = c.read(conversationsProvider.notifier);
    final first = n.refresh();
    final second = n.refresh();
    svc.requests[1].complete([item(1)]);
    await second;
    svc.requests[0].complete([item(3)]);
    await first;
    expect(c.read(conversationsProvider).requireValue.single.unreadCount, 1);
  });
  test(
      'refresh begun after click but before read acknowledgement cannot restore red dot',
      () async {
    final n = c.read(conversationsProvider.notifier);
    final ticket = n.beginRead('c');
    final pending = n.refresh();
    svc.requests.last.complete([item(3)]);
    await pending;
    expect(c.read(conversationsProvider).requireValue.single.unreadCount, 0);
    n.completeRead('c', ticket);
    final later = n.refresh();
    svc.requests.last.complete([item(1)]);
    await later;
    expect(c.read(conversationsProvider).requireValue.single.unreadCount, 1);
  });
}
