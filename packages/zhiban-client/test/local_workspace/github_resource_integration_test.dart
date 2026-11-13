// Explicit opt-in against the exported real static publication, no Bus involved.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/community_resources.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_employee_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_installer.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy official images migrate without changing private images', () {
    final hash = 'a' * 64;
    for (final kind in ['agents', 'skills']) {
      final segment = kind == 'agents' ? 'avatar' : 'icon';
      expect(
          CommunityResources.imageUrl(
              'https://old.example/api/public/v1/$kind/id/$segment/$hash.png'),
          '${kind == 'agents' ? CommunityResources.agentsBaseUrl : CommunityResources.skillsBaseUrl}assets/$kind/$hash.png');
    }
    const custom = 'https://private.example/avatar/my-image.png';
    expect(CommunityResources.imageUrl(custom), custom);
  });
  const path = String.fromEnvironment('COMMUNITY_RESOURCE_SITE');
  test(
      'all exported employees, images and skill packages work without backend',
      () => HttpOverrides.runWithHttpOverrides(() async {
            SharedPreferences.setMockInitialValues({});
            final root = Directory(path).absolute;
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            addTearDown(() => server.close(force: true));
            final paths = <String>[];
            final errors = <String>[];
            server.listen((req) async {
              paths.add(req.uri.path);
              if (req.method != 'GET' ||
                  req.headers.value('authorization') != null) {
                errors.add('non-anonymous/static request');
              }
              final file = File('${root.path}${req.uri.path}');
              if (req.uri.path.contains('..') || !await file.exists()) {
                req.response.statusCode = 404;
                await req.response.close();
                return;
              }
              req.response.headers.contentType = req.uri.path.endsWith('.json')
                  ? ContentType.json
                  : req.uri.path.endsWith('.zip')
                      ? ContentType('application', 'zip')
                      : ContentType('application', 'octet-stream');
              await req.response.addStream(file.openRead());
              await req.response.close();
            });
            final base = 'http://127.0.0.1:${server.port}/';
            final dio = Dio(BaseOptions(baseUrl: '${base}skills/'));
            addTearDown(() => dio.close(force: true));
            final employeeDio = Dio(BaseOptions(baseUrl: '${base}agents/'));
            addTearDown(() => employeeDio.close(force: true));
            final employees =
                await CommunityEmployeeCatalog(dio: employeeDio).fetch();
            final client = CommunitySkillCatalog(dio: dio);
            final data = await client.fetch();
            final rows = (data['items'] as List).cast<Map>();
            expect(employees, isNotEmpty);
            expect(rows, isNotEmpty);
            final ids = rows.map((r) => r['skill_uuid']).toSet();
            for (final employee in employees) {
              expect(ids.containsAll(employee['skill_uuids'] as List), true);
            }
            final imageUrls = {
              for (final e in employees) e['avatar_url'] as String? ?? '',
              for (final s in rows) s['icon_url'] as String? ?? ''
            }..remove('');
            for (final url in imageUrls) {
              final result = await dio.get<List<int>>(url,
                  options: Options(responseType: ResponseType.bytes));
              expect(sha256.convert(result.data!).toString(),
                  Uri.parse(url).pathSegments.last.split('.').first);
              final codec = await ui
                  .instantiateImageCodec(Uint8List.fromList(result.data!));
              final frame = await codec.getNextFrame();
              expect(frame.image.width, greaterThan(0));
              expect(frame.image.height, greaterThan(0));
              frame.image.dispose();
              codec.dispose();
            }
            for (final row in rows) {
              final bundle =
                  await client.downloadBundle(row['skill_uuid'] as String);
              final parsed = parseCommunitySkillBundle({
                'bytes': bundle.bytes,
                'sha256': bundle.sha256,
                'code': row['code'] as String,
                'version': row['latest_version'] as String
              });
              expect((parsed['prompt'] as String).trim().isNotEmpty, true);
            }
            expect(errors, isEmpty);
            expect(paths.any((p) => p.startsWith('/api/')), false);
            // Do not expose prompts, content or credentials in logs.
            debugPrint(
                'Verified ${employees.length} employees, ${rows.length} bundles, ${imageUrls.length} images over anonymous static HTTP');
          }, _RealHttp()),
      skip:
          path.isEmpty ? 'Requires explicit local exported publication' : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
