import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/local_installation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('nexwork/local_agent_key_store'),
            (_) async => throw StateError('Old Keychain must not be accessed'));
  });
  test(
      'stable installation across reloads, concurrent starts and localhost aliases',
      () async {
    final ids = await Future.wait(List.generate(
        8,
        (_) => LocalInstallationStore.loadOrCreate(
            'http://localhost:8080/api/agent-bus/v1/')));
    expect(ids.toSet(), hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
    SharedPreferences.setMockInitialValues(saved);
    expect(
        await LocalInstallationStore.loadOrCreate(
            'http://127.0.0.1:8080/api/agent-bus/v1'),
        ids.first);
    expect(saved.values, [ids.first]);
    expect(ids.first, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });
  test('different API environments use independent identifiers', () async {
    final dev = await LocalInstallationStore.loadOrCreate(
        'http://127.0.0.1:8080/api/agent-bus/v1');
    final prod = await LocalInstallationStore.loadOrCreate(
        'https://api.example.com/api/agent-bus/v1');
    expect(prod, isNot(dev));
  });
  test('corrupt existing identity fails without silent replacement', () async {
    const url = 'https://api.example.com/api/agent-bus/v1';
    await LocalInstallationStore.loadOrCreate(url);
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getKeys().single;
    await prefs.setString(key, 'invalid');
    await expectLater(
        LocalInstallationStore.loadOrCreate(url), throwsStateError);
    expect(prefs.getString(key), 'invalid');
  });
}
