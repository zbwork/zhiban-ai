import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_cache.dart';

// Remote transport uses a locally generated signed fixture. Everything from the
// durable cache through loopback, Sparkle signature verification and replacement
// is real. Never targets the user's running cn.qkfintech.zhiban application.
class FixtureAdapter implements HttpClientAdapter {
  FixtureAdapter(this.root);
  final Directory root;
  int downloads = 0;
  bool offline = false;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (offline) throw const SocketException('remote unavailable');
    final archive = File('${root.path}/fixture.dmg');
    if (options.uri.path == '/feed') {
      final signature = Platform.environment['EASYO_REJECT_SIGNATURE'] == '1'
          ? base64Encode(List<int>.filled(64, 1))
          : await File('${root.path}/signature').readAsString();
      return ResponseBody.fromString(
          '''<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated update verification</title><item>
<sparkle:version>101</sparkle:version><sparkle:shortVersionString>0.0.101</sparkle:shortVersionString>
<enclosure url="https://fixture.invalid/package.dmg" length="${await archive.length()}" type="application/octet-stream" sparkle:edSignature="$signature" />
</item></channel></rss>''', 200);
    }
    downloads++;
    return ResponseBody(archive.openRead().map(Uint8List.fromList), 200,
        headers: {
          Headers.contentLengthHeader: ['${await archive.length()}']
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('macOS cached package passes real Sparkle install and confirmed cleanup',
      () async {
    final root = Directory(Platform.environment['EASYO_UPDATE_PROBE'] ??
        '/tmp/easyo-native-update-probe');
    final rejectSignature =
        Platform.environment['EASYO_REJECT_SIGNATURE'] == '1';
    final app = '${root.path}/100/EasyOUpdateFixture.app';
    final adapter = FixtureAdapter(root);
    Future<String> installedBuild() async {
      final result = await Process.run('/usr/libexec/PlistBuddy',
          ['-c', 'Print CFBundleVersion', '$app/Contents/Info.plist']);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
      return result.stdout.toString().trim();
    }

    DesktopUpdateCache cache() => DesktopUpdateCache(
        platform: 'macos',
        directory: () async => Directory(
            '${root.path}/${rejectSignature ? 'cache-rejected' : 'cache'}/'),
        installedBuild: installedBuild,
        dio: Dio()..httpClientAdapter = adapter);
    const info = AppUpdateInfo(
        currentVersion: '0.0.100',
        currentBuildNumber: '100',
        latestVersion: '0.0.101',
        latestBuildNumber: '101',
        isUpdateAvailable: true);
    var instance = cache();
    final downloaded = await instance.download(
        info, Uri.parse('https://fixture.invalid/feed'));
    expect(adapter.downloads, 1);
    await instance.close();
    adapter.offline = true;
    instance = cache();
    addTearDown(instance.close);
    final restored = await instance.download(
        info, Uri.parse('https://fixture.invalid/feed'));
    expect(restored.archive.path, downloaded.archive.path);
    expect(adapter.downloads, 1);
    final feed = await instance.installationFeed(restored);
    await File('${root.path}/feed-url').writeAsString(feed.toString());
    final stateFile = File('${root.path}/native-state.json');
    if (await stateFile.exists()) await stateFile.delete();
    final launch = await Process.run('open', ['-n', app]);
    expect(launch.exitCode, 0, reason: '${launch.stderr}');
    Future<Map<String, dynamic>> waitFor(String event, {String? build}) async {
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!await stateFile.exists()) continue;
        final state =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        final message = state['event'] as String;
        if (event == 'rejected' && message.startsWith('failed')) {
          return state;
        }
        if (message.startsWith('failed') || message.startsWith('notFound')) {
          fail(message);
        }
        if (message == event && (build == null || state['build'] == build)) {
          return state;
        }
      }
      fail('Timed out waiting for $event: ${await stateFile.readAsString()}');
    }

    if (rejectSignature) {
      final rejected = await waitFor('rejected');
      stderr.writeln(
          'Native Sparkle rejected the invalid publisher signature: $rejected');
      expect(await installedBuild(), '100');
      expect(await restored.archive.exists(), isTrue);
      expect(await instance.restore(), isNotNull);
      await File('${root.path}/native-command').writeAsString('quit');
      return;
    }
    final ready = await waitFor('ready');
    stderr.writeln('Sparkle ready after real signature verification: $ready');
    expect(await restored.archive.exists(), isTrue);
    // Native install remains explicit: merely reaching ready never cleans cache.
    expect(await instance.restore(), isNotNull);
    await File('${root.path}/native-command').writeAsString('install');
    final updated = await waitFor('started', build: '101');
    stderr.writeln('Sparkle replaced and relaunched isolated app: $updated');
    expect(await installedBuild(), '101');
    expect(await instance.restore(), isNull);
    expect(await restored.archive.exists(), isFalse);
    expect(adapter.downloads, 1);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
