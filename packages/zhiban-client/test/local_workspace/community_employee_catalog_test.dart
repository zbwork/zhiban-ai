import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:zhiban_client/pages/local_workspace/services/community_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_employee_catalog.dart';

Map<String, dynamic> employee(String id) => {
      'uuid': id,
      'name': '写作助手',
      'system_prompt': '帮用户写作',
      'skill_uuids': <String>[],
      'requires_backend': false,
      'execution_locus': 'local',
      'local_engine': 'dsh',
    };
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('anonymous pagination caches complete official catalog', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example'));
    var requests = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.headers.containsKey('Authorization'), isFalse);
      expect(options.path, '/api/public/v1/agents');
      final offset = options.queryParameters['offset'] as int;
      requests++;
      handler.resolve(Response(requestOptions: options, data: {
        'success': true,
        'data': {
          'total': 51,
          'items': [
            for (var i = offset; i < (offset == 0 ? 50 : 51); i++)
              employee('$i'),
          ]
        },
      }));
    }));
    final client = CommunityEmployeeCatalog(dio: dio);
    expect(await client.fetch(), hasLength(51));
    expect(requests, 2);
    expect(await client.cached(), hasLength(51));
  });
  test('public avatar uses the catalog origin and survives cached reload',
      () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example/root'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, data: {
        'success': true,
        'data': {
          'total': 1,
          'items': [
            {
              ...employee('one'),
              'avatar_url': '/api/public/v1/agents/one/avatar/hash.png'
            }
          ]
        },
      }));
    }));
    final catalog = CommunityEmployeeCatalog(dio: dio);
    expect((await catalog.fetch()).single['avatar_url'],
        'https://catalog.example/api/public/v1/agents/one/avatar/hash.png');
    expect((await catalog.cached()).single['avatar_url'],
        'https://catalog.example/api/public/v1/agents/one/avatar/hash.png');
  });
  test('invalid refresh does not overwrite last successful cache', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example'));
    var invalid = false;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, data: {
        'success': true,
        'data': {
          'total': invalid ? 2 : 1,
          'items':
              invalid ? [employee('one'), employee('one')] : [employee('one')]
        },
      }));
    }));
    final client = CommunityEmployeeCatalog(dio: dio);
    await client.fetch();
    invalid = true;
    await expectLater(client.fetch(), throwsFormatException);
    expect(await client.cached(), hasLength(1));
    final other = CommunityEmployeeCatalog(
        dio: Dio(BaseOptions(baseUrl: 'https://other.example')));
    expect(await other.cached(), isEmpty);
  });
  test('official employee is copied once and user edits survive repeated use',
      () async {
    sqfliteFfiInit();
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final controller = LocalWorkspaceController(store);
    addTearDown(() async {
      controller.dispose();
      await store.db.close();
    });
    final item = {
      ...employee('one'),
      'local_engine': 'codex_app_server',
      'intro': '帮用户起草邮件',
      'description': 'V2候选，角色ID：内部备注',
    };
    final id = await controller.useOfficialEmployee(item);
    expect(controller.employees.single['id'], id);
    expect(
        jsonDecode(
            controller.employees.single['metadata'] as String)['description'],
        '帮用户起草邮件');
    expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(id),
        isTrue);
    expect(
        jsonDecode(controller.employees.single['metadata'] as String)[
            'source_template_uuid'],
        'one');
    await controller
        .saveEmployee({...controller.employees.single, 'name': '自己修改的名字'});
    expect(await controller.useOfficialEmployee({...item, 'name': '官方新版'}), id);
    expect(controller.employees, hasLength(1));
    expect(controller.employees.single['name'], '自己修改的名字');
    expect(await store.messages(id), isEmpty);
  });
  test('avatar refresh keeps official conversation identity and history',
      () async {
    sqfliteFfiInit();
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final controller = LocalWorkspaceController(store);
    addTearDown(() async {
      controller.dispose();
      await store.db.close();
    });
    final item = {
      ...employee('one'),
      'avatar_url': 'https://catalog.example/old.png'
    };
    final id = await controller.useOfficialEmployee(item);
    await store.addMessage(id, 'user', 'keep history');
    await controller.saveEmployee({
      ...controller.employees.single,
      'provider_id': 'existing-provider',
      'model_id': 'existing-model'
    });
    expect(
        await controller.useOfficialEmployee(
            {...item, 'avatar_url': 'https://catalog.example/new.png'}),
        id);
    final row = controller.employees.single;
    expect(jsonDecode(row['metadata'] as String)['avatar_url'],
        'https://catalog.example/new.png');
    expect(row['provider_id'], 'existing-provider');
    expect(row['model_id'], 'existing-model');
    expect((await store.messages(id)).single['content'], 'keep history');
  });
  test(
      'cloud official opens on this computer without requiring backend execution',
      () async {
    sqfliteFfiInit();
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final controller = LocalWorkspaceController(store);
    addTearDown(() async {
      controller.dispose();
      await store.db.close();
    });
    final id = await controller.useOfficialEmployee({
      ...employee('cloud'),
      'requires_backend': true,
      'execution_locus': 'cloud',
      'local_engine': ''
    });
    final row = (await store.employees()).single;
    expect(row['id'], id);
    expect(jsonDecode(row['metadata'] as String)['execution_locus'], 'local');
    expect(jsonDecode(row['metadata'] as String)['local_engine'], 'dsh');
  });
  test(
      'legacy official IDs retain storage identity and get stable execution UUIDs',
      () {
    const uuid = '68de7f34-fa8b-47ca-9cf4-b775475a2d2b';
    expect(CommunityRuntime.employeeIdentity(uuid), uuid);
    final legacy = 'official-$uuid';
    final execution = CommunityRuntime.employeeIdentity(legacy);
    expect(execution, CommunityRuntime.employeeIdentity(legacy));
    expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(execution),
        isTrue);
    expect(() => CommunityRuntime.employeeIdentity('not-an-employee'),
        throwsA(isA<Exception>()));
  });
  test(
      'legacy official copy is reused without changing history or configuration',
      () async {
    sqfliteFfiInit();
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final controller = LocalWorkspaceController(store);
    addTearDown(() async {
      controller.dispose();
      await store.db.close();
    });
    const source = '68de7f34-fa8b-47ca-9cf4-b775475a2d2b';
    const legacy = 'official-$source';
    await controller.saveEmployee({
      'id': legacy,
      'name': '已修改的员工',
      'prompt': '保留人设',
      'provider_id': '',
      'model_id': '',
      'skills': '[]',
      'created': 1,
      'metadata': jsonEncode({'source_template_uuid': source})
    });
    await store.addMessage(legacy, 'user', '保留历史');
    expect(await controller.useOfficialEmployee(employee(source)), legacy);
    expect(controller.employees.single['name'], '已修改的员工');
    expect((await store.messages(legacy)).single['content'], '保留历史');
  });
}
