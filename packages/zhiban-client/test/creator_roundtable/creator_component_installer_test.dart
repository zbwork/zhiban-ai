import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_component_installer.dart';

void main() {
  for (final corrupt in [false, true]) {
    test('模型镜像${corrupt ? '校验失败' : '返回 503'}后切换来源并复用缓存', () async {
      final root = await Directory.systemTemp.createTemp('creator-mirror-');
      addTearDown(() => root.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      final bytes = utf8.encode('verified model');
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/mirror') {
          if (corrupt) {
            request.response.write('invalid model, longer than expected');
          } else {
            request.response.statusCode = HttpStatus.serviceUnavailable;
          }
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      final progress = <String>[];
      final installer =
          CreatorComponentInstaller('runtime', supportDirectory: root);
      final origin = 'http://127.0.0.1:${server.port}';
      Future<String> prepare() => installer.prepare(
            label: '本机多语种模型',
            url: '$origin/mirror',
            fallbackUrl: '$origin/official',
            digest: sha256.convert(bytes).toString(),
            output: 'model.bin',
            progress: progress.add,
          );
      final path = await prepare();
      expect(await File(path).readAsBytes(), bytes);
      expect(progress, contains('正在切换本机多语种模型下载源…'));
      expect(await prepare(), path);
      expect(requests, ['/mirror', '/official']);
    });
  }
}
