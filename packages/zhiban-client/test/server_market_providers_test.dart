import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_employee_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_catalog.dart';
import 'package:zhiban_client/pages/server_connection/community_market_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'server workspace reads anonymous public origin and preserves template fields',
      () async {
    final previous = AppConfig.serverApiUrl;
    AppConfig.serverApiUrl = 'http://127.0.0.1:38080/api/agent-bus/v1';
    addTearDown(() => AppConfig.serverApiUrl = previous);
    final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.uri.host, 'catalog.example');
      expect(options.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')));
      handler.resolve(Response(requestOptions: options, data: {
        'success': true,
        'data': {
          'total': 1,
          'items': [
            {
              'uuid': 'template',
              'name': '公共助手',
              'intro': '公开简介',
              'description': '内部描述',
              'system_prompt': '帮助用户',
              'position_label': '顾问',
              'skill_uuids': <String>[],
              'requires_backend': true,
            }
          ]
        }
      }));
    }));
    final container = ProviderContainer(overrides: [
      communityEmployeeClientProvider
          .overrideWithValue(CommunityEmployeeCatalog(dio: dio)),
    ]);
    addTearDown(container.dispose);
    final subscription =
        container.listen(communityEmployeesProvider, (_, __) {});
    addTearDown(subscription.close);
    final employee =
        (await container.read(communityEmployeesProvider.future)).single;
    expect(employee.positionLabel, '顾问');
    expect(employee.modelPrimary, isEmpty);
    expect(employee.systemPrompt, '帮助用户');
    expect(employee.supportsSkillBindings, isFalse);
  });
  test('public skill failure remains an error and can be retried', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://catalog.example'));
    var failing = true;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (failing) {
        handler.reject(DioException(requestOptions: options));
        return;
      }
      handler.resolve(Response(requestOptions: options, data: {
        'success': true,
        'data': {
          'total': 1,
          'categories': <Object>[],
          'items': [
            {
              'skill_uuid': 'skill',
              'code': 'test_skill',
              'name': '测试技能',
            }
          ]
        }
      }));
    }));
    final container = ProviderContainer(retry: (_, __) => null, overrides: [
      communitySkillClientProvider
          .overrideWithValue(CommunitySkillCatalog(dio: dio))
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(communitySkillsProvider, (_, __) {});
    addTearDown(subscription.close);
    await expectLater(container.read(communitySkillsProvider.future),
        throwsA(isA<DioException>()));
    failing = false;
    container.invalidate(communitySkillsProvider);
    expect(
        (await container.read(communitySkillsProvider.future))
            .skills
            .single
            .displayName,
        '测试技能');
  });
}
