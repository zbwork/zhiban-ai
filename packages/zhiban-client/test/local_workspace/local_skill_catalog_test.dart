import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('fresh workspace has no bundled skill catalog', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    expect(await store.skills(), isEmpty);
    await store.db.close();
  });

  test('v1 upgrade preserves chats and bindings without seeding catalog',
      () async {
    final dir = await Directory.systemTemp.createTemp('community-catalog-');
    final path = '${dir.path}/workspace.db';
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
                'CREATE TABLE employees (id TEXT PRIMARY KEY, name TEXT, prompt TEXT, provider_id TEXT, model_id TEXT, skills TEXT, created INTEGER)');
            await db.execute(
                'CREATE TABLE messages (id TEXT PRIMARY KEY, employee_id TEXT, role TEXT, content TEXT, status TEXT, created INTEGER)');
            await db.execute(
                'CREATE TABLE skills (id TEXT PRIMARY KEY, name TEXT, description TEXT, prompt TEXT)');
          },
        ));
    final employee = <String, Object?>{
      'id': 'e',
      'name': '助手',
      'prompt': '帮助',
      'provider_id': 'p',
      'model_id': 'm',
      'skills': '["summary"]',
      'created': 1
    };
    await old.insert('employees', employee);
    await old.insert('messages', {
      'id': 'm',
      'employee_id': 'e',
      'role': 'user',
      'content': '保留聊天',
      'status': 'complete',
      'created': 1
    });
    await old.close();
    var store =
        await LocalWorkspaceStore.open(factory: databaseFactoryFfi, path: path);
    expect(await store.skills(), isEmpty);
    expect((await store.employees()).single['skills'], '["summary"]');
    expect((await store.messages('e')).single['content'], '保留聊天');
    await store.db.insert('skills', {
      'id': 'not-installed',
      'name': '未安装',
      'description': '',
      'prompt': '',
      'executable': 0
    });
    final controller = LocalWorkspaceController(store);
    await controller.refresh();
    const missing = {'id': 'not-installed'};
    await expectLater(
        controller.saveEmployee({
          ...employee,
          'skills': jsonEncode([missing['id']])
        }),
        throwsStateError);
    controller.dispose();
    await store.db.insert('skills', {
      'id': 'old-metadata-only',
      'name': '旧目录',
      'description': '旧快照',
      'prompt': '',
      'executable': 0
    });
    await store.db.close();
    store =
        await LocalWorkspaceStore.open(factory: databaseFactoryFfi, path: path);
    expect((await store.skills()).where((s) => s['listed'] != 0), isEmpty);
    expect((await store.skills()).any((s) => s['id'] == 'old-metadata-only'),
        isTrue);
    expect((await store.messages('e')).single['content'], '保留聊天');
    await store.db.close();
    await dir.delete(recursive: true);
  });
}
