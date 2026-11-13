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
      expect(request.uri.path, '/catalog/v1/skills.json');
      expect(request.headers.value('authorization'), isNull);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'format_version': 1,
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

  test('public skill icon uses catalog origin, not commercial API environment',
      () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example/root'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, data: {
        'format_version': 1,
        'success': true,
        'data': {
          'items': [
            {
              'skill_uuid': 'one',
              'code': 'one',
              'name': 'One',
              'icon_url': 'assets/skills/hash.png'
            }
          ],
          'categories': [],
          'total': 1
        },
      }));
    }));
    final data = await CommunitySkillCatalog(dio: dio).fetch();
    expect(data['items'][0]['icon_url'],
        'https://catalog.example/root/assets/skills/hash.png');
  });

  for (final redirect in [false, true]) {
    test('static bundle GET uses manifest digest; unsafe redirect=$redirect',
        () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example/project/'));
      var bundleRequests = 0;
      final hash = 'a' * 64;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.method, 'GET');
        expect(options.headers.containsKey('Authorization'), false);
        if (options.path.endsWith('skills.json')) {
          handler.resolve(Response(requestOptions: options, data: {
            'format_version': 1,
            'success': true,
            'data': {
              'total': 1,
              'categories': [],
              'items': [
                {
                  'skill_uuid': 'one',
                  'code': 'demo',
                  'name': 'Demo',
                  'bundle_url': 'packages/demo.zip',
                  'bundle_sha256': hash
                }
              ]
            }
          }));
        } else {
          bundleRequests++;
          handler.resolve(Response(
              requestOptions: options,
              statusCode: redirect ? 302 : 200,
              data: ResponseBody.fromBytes([80, 75, 3, 4], redirect ? 302 : 200,
                  headers: {
                    'content-type': ['application/octet-stream'],
                    if (redirect)
                      'location': ['https://untrusted.example/package.zip']
                  }),
              headers: Headers.fromMap({
                if (redirect)
                  'location': ['https://untrusted.example/package.zip']
              })));
        }
      }));
      final client = CommunitySkillCatalog(dio: dio);
      if (redirect) {
        await expectLater(client.downloadBundle('one'), throwsFormatException);
      } else {
        final bundle = await client.downloadBundle('one');
        expect(bundle.sha256, hash);
        expect(bundle.bytes, [80, 75, 3, 4]);
      }
      expect(bundleRequests, 1);
    });
  }

  test('bundle metadata cannot escape Pages packages or use a Release',
      () async {
    for (final path in [
      'https://github.com/zbwork/skills/releases/download/test/demo.zip',
      '../agents/packages/demo.zip',
      'catalog/v1/skills.json',
      'https://catalog.example.evil/project/packages/demo.zip',
    ]) {
      final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example/project/'));
      var requests = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests++;
        handler.resolve(Response(requestOptions: options, data: {
          'format_version': 1,
          'success': true,
          'data': {
            'total': 1,
            'categories': [],
            'items': [
              {
                'skill_uuid': 'one',
                'code': 'demo',
                'name': 'Demo',
                'bundle_url': path,
                'bundle_sha256': 'a' * 64,
              }
            ]
          },
        }));
      }));
      await expectLater(CommunitySkillCatalog(dio: dio).downloadBundle('one'),
          throwsFormatException);
      expect(requests, 1, reason: 'Reject before any package request: $path');
      dio.close(force: true);
    }
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
    expect(
        (await store.skills()).firstWhere((s) => s['id'] == 'old')['icon_url'],
        isEmpty);
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
