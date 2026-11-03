import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';

class CountingStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  int reads = 0;
  bool fail = false;
  bool failWrite = false;
  Completer<String?>? pending;
  @override
  Future<String?> read(
      {required String key,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    reads++;
    if (fail) throw PlatformException(code: 'denied');
    if (pending != null) return await pending!.future;
    return values[key];
  }

  @override
  Future<void> write(
      {required String key,
      required String? value,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (failWrite) throw PlatformException(code: 'denied');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete(
      {required String key,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'model_service.api_key.community-local.cache-test';
  late CountingStorage secure;
  late ModelServiceStore store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ModelServiceStore.clearApiKeyMemoryCache();
    secure = CountingStorage()..values[key] = 'test-key';
    store = ModelServiceStore(secureStorage: secure);
  });
  tearDown(ModelServiceStore.clearApiKeyMemoryCache);

  test(
      'repeated and concurrent reads across store instances access Keychain once',
      () async {
    final other = ModelServiceStore(secureStorage: secure);
    secure.pending = Completer<String?>();
    final first = store.getApiKey('cache-test');
    final second = other.getApiKey('cache-test');
    await Future<void>.delayed(Duration.zero);
    expect(secure.reads, 1);
    secure.pending!.complete('test-key');
    expect(await Future.wait([first, second]), ['test-key', 'test-key']);
    expect(await other.getApiKey('cache-test'), 'test-key');
    expect(secure.reads, 1);
  });
  test('save primes cache; replace and delete never reuse old key', () async {
    await store.setApiKey('cache-test', 'new-key');
    expect(await store.getApiKey('cache-test'), 'new-key');
    expect(secure.reads, 0);
    await store.setApiKey('cache-test', 'replacement');
    expect(await store.getApiKey('cache-test'), 'replacement');
    await store.deleteApiKey('cache-test');
    expect(await store.getApiKey('cache-test'), isNull);
    expect(await store.getApiKey('cache-test'), isNull);
    expect(secure.reads, 1);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });
  test('denied read retries; failed save evicts old cache', () async {
    secure.fail = true;
    await expectLater(
        store.getApiKey('cache-test'), throwsA(isA<PlatformException>()));
    secure.fail = false;
    expect(await store.getApiKey('cache-test'), 'test-key');
    expect(secure.reads, 2);
    secure.failWrite = true;
    await expectLater(store.setApiKey('cache-test', 'invalid'),
        throwsA(isA<PlatformException>()));
    expect(await store.getApiKey('cache-test'), 'test-key');
    expect(secure.reads, 3);
  });
  test('late read cannot overwrite saved or deleted key', () async {
    secure.pending = Completer<String?>();
    final read = store.getApiKey('cache-test');
    await Future<void>.delayed(Duration.zero);
    await store.setApiKey('cache-test', 'new-key');
    secure.pending!.complete('old-key');
    await read;
    expect(await store.getApiKey('cache-test'), 'new-key');
    ModelServiceStore.clearApiKeyMemoryCache();
    secure.pending = Completer<String?>();
    final second = store.getApiKey('cache-test');
    await Future<void>.delayed(Duration.zero);
    await store.deleteApiKey('cache-test');
    secure.pending!.complete('old-key');
    await second;
    secure.pending = null;
    expect(await store.getApiKey('cache-test'), isNull);
  });
}
