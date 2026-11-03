import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/services/local_api_key_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local file persists across cache reset, restricts access and deletes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('key-file-test-');
    addTearDown(() => root.delete(recursive: true));
    addTearDown(ModelServiceStore.clearApiKeyMemoryCache);
    final files = LocalApiKeyFileStore(root: root);
    final store = ModelServiceStore(fileStore: files);
    await store.setApiKey('file-provider', 'fixture-key');
    ModelServiceStore.clearApiKeyMemoryCache();
    expect(await ModelServiceStore(fileStore: files).getApiKey('file-provider'),
        'fixture-key');
    final file = root.listSync().single as File;
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
      expect(root.statSync().mode & 0x1ff, 0x1c0);
    }
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    file.deleteSync();
    final target = File('${root.path}/outside')..writeAsStringSync('keep');
    Link(file.path).createSync(target.path);
    ModelServiceStore.clearApiKeyMemoryCache();
    await expectLater(
        store.getApiKey('file-provider'), throwsA(isA<FileSystemException>()));
    Link(file.path).deleteSync();
    await store.setApiKey('file-provider', 'replaced');
    await store.deleteApiKey('file-provider');
    expect(await store.getApiKey('file-provider'), isNull);
    expect(target.readAsStringSync(), 'keep');
  });
}
