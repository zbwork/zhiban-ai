import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

void main() {
  sqfliteFfiInit();
  test('catalog uses anonymous public endpoint and rejects partial responses',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var valid = true;
    server.listen((request) async {
      expect(request.uri.path, '/api/public/v1/skills');
      expect(request.headers.value('authorization'), isNull);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'data': {'items': [], 'categories': [], 'total': valid ? 0 : 10}
      }));
      await request.response.close();
    });
    final client = CommunitySkillCatalog(
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')));
    expect((await client.fetch())['items'], isEmpty);
    valid = false;
    await expectLater(client.fetch(), throwsFormatException);
  });

  test('market uses only current Bus response and clears on failure', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final controller = LocalWorkspaceController(store);
    final client = StubCatalog();
    try {
      await controller.syncSkillCatalog(client: client);
      expect(controller.marketSkillIds, {'server-uuid'});
      await controller.refresh();
      expect(controller.marketSkillIds, {'server-uuid'});
      client.fail = true;
      await controller.syncSkillCatalog(client: client);
      expect(controller.marketSkillIds, isEmpty);
      expect(controller.skillCategories, isEmpty);
      expect(controller.catalogError, contains('刷新'));
      expect(await store.skills(), isNotEmpty);
      final reopened = LocalWorkspaceController(store);
      await reopened.refresh();
      expect(reopened.marketSkillIds, isEmpty);
      reopened.dispose();
      client.fail = false;
      client.empty = true;
      await controller.syncSkillCatalog(client: client);
      expect(controller.marketSkillIds, isEmpty);
      expect(controller.catalogError, isNull);
    } finally {
      controller.dispose();
      await store.db.close();
    }
  });

  test('server catalog survives reopen and empty catalog replaces market',
      () async {
    final dir = await Directory.systemTemp.createTemp('public-catalog-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/workspace.db';
    const seed = {
      'id': 'old',
      'icon_url': 'asset:assets/local_skills/icons/old.png',
      'name': 'old',
      'description': '',
      'prompt': '',
      'executable': 0
    };
    var store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: path, skills: [seed]);
    await store.cacheSkillCatalog({
      'items': [],
      'categories': [],
      'total': 1
    }, [
      {
        'id': 'server-new',
        'name': '服务器技能',
        'description': '',
        'prompt': '',
        'executable': 0,
        'listed': 1
      }
    ]);
    await store.db.close();
    store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: path, skills: [seed]);
    expect((await store.skills()).where((s) => s['listed'] == 1), isEmpty);
    expect((await store.skills()).any((s) => s['name'] == '服务器技能'), isTrue);
    expect(await store.cachedSkillCatalog(), isNotNull);
    expect((await store.skills()).firstWhere((s) => s['id'] == 'old')['icon_url'], isEmpty);
    await store
        .cacheSkillCatalog({'items': [], 'categories': [], 'total': 0}, []);
    expect((await store.skills()).where((s) => s['listed'] == 1), isEmpty);
    await store.db.close();
  });
}

class StubCatalog extends CommunitySkillCatalog {
  bool fail = false, empty = false;
  @override
  Future<Map<String, dynamic>> fetch() async {
    if (fail) throw StateError('offline');
    return {
      'items': empty
          ? []
          : [
              {'code': 'new-code', 'skill_uuid': 'uuid', 'name': 'Bus技能'}
            ],
      'categories': [],
      'total': empty ? 0 : 1
    };
  }
}
