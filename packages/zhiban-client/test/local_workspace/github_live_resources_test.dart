// Explicit live verification: real GitHub Pages, no Bus/mock server.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/community_resources.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_employee_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_catalog.dart';
import 'package:zhiban_client/pages/local_workspace/services/community_skill_installer.dart';

class _RealHttp extends HttpOverrides {}

Future<void> batches<T>(List<T> items, Future<void> Function(T) fn) async {
  for (var i = 0; i < items.length; i += 4) {
    await Future.wait(
        items.sublist(i, i + 4 < items.length ? i + 4 : items.length).map(fn));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('VERIFY_GITHUB');
  test(
      'all live GitHub images and packages use anonymous trusted hosts',
      () => HttpOverrides.runWithHttpOverrides(() async {
            SharedPreferences.setMockInitialValues({});
            final audit = <Map<String, Object?>>[];
            final counts = <String, Object?>{};
            Dio client(String base) {
              final dio = Dio(BaseOptions(
                  baseUrl: base,
                  followRedirects: false,
                  connectTimeout: const Duration(seconds: 8),
                  receiveTimeout: const Duration(seconds: 15)));
              dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
                expect(o.uri.host == 'zbwork.github.io', true);
                expect(o.method, 'GET');
                expect(
                    o.headers.keys
                        .any((k) => k.toLowerCase() == 'authorization'),
                    false);
                expect(o.uri.scheme, 'https');
                h.next(o);
              }, onResponse: (r, h) {
                audit.add({
                  'host': r.requestOptions.uri.host,
                  'path': r.requestOptions.uri.path,
                  'status': r.statusCode
                });
                h.next(r);
              }));
              addTearDown(() => dio.close(force: true));
              return dio;
            }

            try {
              final employeeDio = client(CommunityResources.agentsBaseUrl);
              final skillDio = client(CommunityResources.skillsBaseUrl);
              final employees =
                  await CommunityEmployeeCatalog(dio: employeeDio).fetch();
              final skillClient = CommunitySkillCatalog(dio: skillDio);
              final data = await skillClient.fetch();
              final rows = (data['items'] as List).cast<Map>();
              expect(employees.length, 20);
              expect(rows.length, 81);
              final ids = rows.map((r) => r['skill_uuid']).toSet();
              for (final e in employees) {
                expect(ids.containsAll(e['skill_uuids'] as List), true);
              }
              final images = {
                for (final e in employees) e['avatar_url'] as String? ?? '',
                for (final s in rows) s['icon_url'] as String? ?? ''
              }..remove('');
              await batches(images.toList(), (url) async {
                final response = await skillDio.get<List<int>>(url,
                    options: Options(responseType: ResponseType.bytes));
                expect(sha256.convert(response.data!).toString(),
                    Uri.parse(url).pathSegments.last.split('.').first);
                final codec = await ui
                    .instantiateImageCodec(Uint8List.fromList(response.data!));
                final frame = await codec.getNextFrame();
                expect(frame.image.width, greaterThan(0));
                expect(frame.image.height, greaterThan(0));
                frame.image.dispose();
                codec.dispose();
              });
              counts['employees'] = employees.length;
              counts['images'] = images.length;
              await batches(rows, (row) async {
                final bundle = await skillClient
                    .downloadBundle(row['skill_uuid'] as String);
                final parsed = parseCommunitySkillBundle({
                  'bytes': bundle.bytes,
                  'sha256': bundle.sha256,
                  'code': row['code'] as String,
                  'version': row['latest_version'] as String
                });
                expect((parsed['prompt'] as String).trim().isNotEmpty, true);
              });
              counts['packages'] = rows.length;
              counts['status'] = 'passed';
              expect(
                  audit
                      .where((e) =>
                          (e['path'] as String).startsWith('/skills/packages/'))
                      .length,
                  81);
              debugPrint('Live GitHub verification passed: $counts');
            } finally {
              await File('/tmp/github-live-resource-audit.json').writeAsString(
                  const JsonEncoder.withIndent('  ')
                      .convert({'checks': counts, 'requests': audit}));
            }
          }, _RealHttp()),
      skip: !live,
      timeout: const Timeout(Duration(minutes: 8)));
}
