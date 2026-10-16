import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_cache.dart';
import 'package:xml/xml.dart';

const sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

// The adapter maps only this test origin to an actual loopback HTTP server.
// Cache validation, persistence, native downloads and signature checks are real.
class LoopbackTransport implements HttpClientAdapter {
  LoopbackTransport(this.origin);
  final Uri origin;
  final client = HttpClient();
  final downloads = <String>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.uri.host != 'fixture.invalid') {
      throw StateError('Unexpected origin');
    }
    downloads.add(options.uri.path);
    final request =
        await client.getUrl(origin.resolve(options.uri.path.substring(1)));
    final response = await request.close();
    return ResponseBody(response.map(Uint8List.fromList), response.statusCode,
        headers: {
          Headers.contentLengthHeader: ['${response.contentLength}']
        });
  }

  @override
  void close({bool force = false}) => client.close(force: force);
}

void main() {
  for (final scenario in ['delta', 'missing', 'mismatch']) {
    test('real Sparkle $scenario installs 100 to 101', () async {
      final root = Directory(
          Directory(Platform.environment['EASYO_UPDATE_PROBE']!)
              .resolveSymbolicLinksSync());
      final installed =
          Directory('${root.path}/running/EasyOUpdateFixture.app');
      if (await installed.exists()) await installed.delete(recursive: true);
      final copied = await Process.run(
          'ditto', ['${root.path}/100/EasyOUpdateFixture.app', installed.path]);
      expect(copied.exitCode, 0);
      for (final name in [
        'native-state.json',
        'native-events.jsonl',
        'native-command'
      ]) {
        final file = File('${root.path}/$name');
        if (await file.exists()) await file.delete();
      }
      final document = XmlDocument.parse(
          await File('${root.path}/updates/appcast.xml').readAsString());
      final channel = document.rootElement.getElement('channel')!;
      final target = channel.findElements('item').singleWhere((item) =>
          item.getElement('version', namespace: sparkle)?.innerText == '101');
      channel.children.removeWhere((node) =>
          node is XmlElement && node.name.local == 'item' && node != target);
      final delta = target
          .findAllElements('deltas', namespace: sparkle)
          .single
          .findElements('enclosure')
          .single;
      final deltaName = Uri.parse(delta.getAttribute('url')!).pathSegments.last;
      if (scenario == 'mismatch') {
        delta.setAttribute('deltaFrom', '99', namespace: sparkle);
      }
      final remoteXml = document.toXmlString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}/');
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        try {
          if (request.uri.path == '/feed') {
            final bytes = utf8.encode(remoteXml);
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
          } else if (request.uri.path == '/$deltaName' &&
              scenario == 'missing') {
            request.response.statusCode = 404;
          } else if (['/$deltaName', '/fixture-101.dmg']
              .contains(request.uri.path)) {
            final file = File('${root.path}/updates${request.uri.path}');
            request.response.headers.contentType = ContentType.binary;
            request.response.contentLength = await file.length();
            await request.response.addStream(file.openRead());
          } else {
            request.response.statusCode = 404;
          }
        } finally {
          await request.response.close();
        }
      });
      addTearDown(() => server.close(force: true));
      final cacheDirectory = Directory('${root.path}/cache-$scenario/');
      if (await cacheDirectory.exists()) {
        await cacheDirectory.delete(recursive: true);
      }
      final transport = LoopbackTransport(origin);
      Future<String> build() async {
        final result = await Process.run('/usr/libexec/PlistBuddy', [
          '-c',
          'Print CFBundleVersion',
          '${installed.path}/Contents/Info.plist'
        ]);
        expect(result.exitCode, 0);
        return result.stdout.toString().trim();
      }

      final cache = DesktopUpdateCache(
          platform: 'macos',
          directory: () async => Directory('${root.path}/cache-$scenario/'),
          installedBuild: build,
          dio: Dio()..httpClientAdapter = transport);
      addTearDown(cache.close);
      final cached = await cache.download(
          const AppUpdateInfo(
              currentVersion: '0.0.100',
              currentBuildNumber: '100',
              latestVersion: '0.0.101',
              latestBuildNumber: '101',
              isUpdateAvailable: true),
          Uri.parse('https://fixture.invalid/feed'));
      expect(cached.packageType, scenario == 'delta' ? 'delta' : 'full');
      // Native fallback requests use the same fixture HTTP origin. Only URLs
      // change, while publisher signatures and version constraints remain intact.
      final native = CachedDesktopUpdate(
          directory: cached.directory,
          buildNumber: cached.buildNumber,
          version: cached.version,
          platform: cached.platform,
          size: cached.size,
          digest: cached.digest,
          packageType: cached.packageType,
          deltaFromBuild: cached.deltaFromBuild,
          appcast: cached.appcast
              .replaceAll('https://fixture.invalid/', origin.toString()));
      final feed = await cache.installationFeed(native);
      await File('${root.path}/feed-url').writeAsString(feed.toString());
      final process = await Process.start(
          '${installed.path}/Contents/MacOS/EasyOUpdateFixture', []);
      final output = File('${root.path}/$scenario-native.log').openWrite();
      final out = process.stdout.listen(output.add);
      final err = process.stderr.listen(output.add);
      addTearDown(() async {
        await File('${root.path}/native-command').writeAsString('quit');
        process.kill();
        await out.cancel();
        await err.cancel();
        await output.close();
        // Kill only the isolated fixture at this exact path after a relaunch.
        await Process.run('pkill', [
          '-f',
          '^${RegExp.escape(installed.path)}/Contents/MacOS/EasyOUpdateFixture\$'
        ]);
      });
      Future<void> waitFor(String expected, {String? version}) async {
        final stateFile = File('${root.path}/native-state.json');
        for (var i = 0; i < 240; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!await stateFile.exists()) continue;
          final state = jsonDecode(await stateFile.readAsString()) as Map;
          if (state['event'].toString().startsWith('failed') ||
              state['event'].toString().startsWith('notFound')) {
            fail('$scenario: $state');
          }
          if (state['event'] == expected &&
              (version == null || state['build'] == version)) {
            return;
          }
        }
        fail('$scenario timeout: ${await stateFile.readAsString()}');
      }

      await waitFor('ready');
      final events =
          (await File('${root.path}/native-events.jsonl').readAsLines())
              .map((line) => jsonDecode(line) as Map)
              .toList();
      final packages = events
          .where((event) => event['event'] == 'sparkleDownloadStarted')
          .map((event) => event['packageType'])
          .toList();
      expect(
          packages,
          scenario == 'delta'
              ? ['delta']
              : scenario == 'missing'
                  ? ['delta', 'full']
                  : ['full']);
      expect(await cached.archive.exists(), isTrue);
      await File('${root.path}/native-command').writeAsString('install');
      await waitFor('started', version: '101');
      expect(await build(), '101');
      expect(await cache.restore(), isNull);
      expect(await cached.archive.exists(), isFalse);
      await File('${root.path}/$scenario-evidence.json')
          .writeAsString(jsonEncode({
        'scenario': scenario,
        'cachePackage': cached.packageType,
        'sparklePackages': packages,
        'installedBuild': await build(),
        'httpRequests': requests,
        'cacheRequests': transport.downloads,
      }));
      stderr.writeln(
          '$scenario: cache=${cached.packageType}, Sparkle=$packages, installed=101, cache cleaned');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
