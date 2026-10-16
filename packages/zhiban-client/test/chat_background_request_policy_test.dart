import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/services/local_runtime_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Interceptor> original;
  late List<RequestOptions> captured;
  setUp(() {
    original = List.of(request.interceptors);
    captured = [];
    request.interceptors.clear();
    request.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      captured.add(options);
      handler.reject(DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      ));
    }));
  });
  tearDown(() {
    request.interceptors.clear();
    request.interceptors.addAll(original);
  });

  const id = '00000000-0000-0000-0000-000000000001';
  final background = <String, Future<Object?> Function()>{
    'conversation list refresh': () =>
        OpenClawChatService().listAllConversations(),
    'desktop status poll': () => LocalRuntimeApi().desktopStatus(),
    'conversation status poll': () => LocalRuntimeApi().conversation(id),
    'approval poll': () => LocalRuntimeApi().approvals(''),
  };
  for (final entry in background.entries) {
    test('${entry.key} opts into silent requests at the real service call',
        () async {
      await expectLater(entry.value(), throwsA(isA<DioException>()));
      expect(captured, hasLength(1));
      expect(captured.single.extra['silent'], isTrue);
    });
  }
  test('conversation list bounds connection and response waiting', () async {
    await expectLater(OpenClawChatService().listAllConversations(),
        throwsA(isA<DioException>()));
    expect(captured.single.extra['pageRead'], true);
    expect(captured.single.receiveTimeout, const Duration(seconds: 20));
  });
  test('user approval keeps normal error feedback', () async {
    await expectLater(
        LocalRuntimeApi().decide({
          'id': id,
          'revision': 1,
          'intent_hash': 'test',
        }, true, 'once'),
        throwsA(isA<DioException>()));
    expect(captured.single.method, 'POST');
    expect(captured.single.extra['silent'], isNot(true));
  });
}
