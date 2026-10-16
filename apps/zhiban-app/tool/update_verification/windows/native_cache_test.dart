import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_cache.dart';

class FixtureAdapter implements HttpClientAdapter {
  FixtureAdapter(this.root, {this.reject = false});
  final Directory root;
  final bool reject;
  var downloads = 0;
  var offline = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (offline) throw const SocketException('remote offline');
    if (options.uri.path == '/feed') {
      final signature = reject
          ? base64Encode(List.filled(64, 1))
          : await File('${root.path}/signature').readAsString();
      return ResponseBody.fromString(
          '''<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated Windows verification</title><item>
<sparkle:version>101</sparkle:version><sparkle:shortVersionString>0.0.0.101</sparkle:shortVersionString>
<enclosure url="https://fixture.invalid/package.exe" length="0" type="application/octet-stream" sparkle:edSignature="$signature" />
</item></channel></rss>''', 200);
    }
    downloads++;
    final archive = File('${root.path}/fixture-101.exe');
    return ResponseBody(archive.openRead().map(Uint8List.fromList), 200,
        headers: {
          Headers.contentLengthHeader: ['${await archive.length()}']
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
      'Windows real WinSparkle rejection, cancellation, offline reuse and install',
      () async {
    final rootPath = Platform.environment['EASYO_UPDATE_PROBE'];
    expect(rootPath, isNotNull, reason: 'Run windows/prepare.ps1 first');
    final root = Directory(rootPath!);
    final executable = File('${root.path}/installed/EasyOUpdateFixture.exe');
    final events = File('${root.path}/native-events.jsonl');
    final installerResult = File('${root.path}/installer-result');
    final caches = <DesktopUpdateCache>[];
    Process? process;

    Future<void> command(String value) async {
      final pending = File('${root.path}/native-command.part');
      await pending.writeAsString(value, flush: true);
      await pending.rename('${root.path}/native-command');
    }

    Future<void> quit() async {
      final running = process;
      if (running == null) return;
      await command('quit');
      await running.exitCode.timeout(const Duration(seconds: 30));
      process = null;
    }

    addTearDown(() async {
      await quit();
      for (final cache in caches) {
        await cache.close();
      }
    });

    Future<String> installedBuild() async {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        r'[Diagnostics.FileVersionInfo]::GetVersionInfo($env:EASYO_FIXTURE_EXE).FilePrivatePart'
      ], environment: {
        'EASYO_FIXTURE_EXE': executable.path
      });
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result.stdout.toString().trim();
    }

    DesktopUpdateCache cache(FixtureAdapter adapter) {
      final instance = DesktopUpdateCache(
          platform: 'windows',
          directory: () async => Directory(
              '${root.path}/${adapter.reject ? 'rejected-cache' : 'cache'}/'),
          installedBuild: installedBuild,
          dio: Dio()..httpClientAdapter = adapter);
      caches.add(instance);
      return instance;
    }

    Future<void> waitFor(
        Future<bool> Function() condition, String description) async {
      for (var i = 0; i < 600; i++) {
        if (await condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      fail('Timed out: $description. Evidence: ${events.path}');
    }

    Future<void> waitEvent(String event) => waitFor(() async {
          if (!await events.exists()) return false;
          final lines = await events.readAsLines();
          for (final line in lines.where((line) => line.endsWith('}'))) {
            final data = jsonDecode(line) as Map<String, dynamic>;
            expect(data['platformThread'], isTrue);
            expect(data['event'], isNot('failedBusyReentry'));
            if (data['event'] == event) return true;
            if (event != 'failed' && data['event'] == 'failed') {
              fail('WinSparkle failed');
            }
          }
          return false;
        }, event);

    Future<void> launch(Uri feed) async {
      if (await events.exists()) await events.delete();
      if (await installerResult.exists()) await installerResult.delete();
      await File('${root.path}/feed-url').writeAsString(feed.toString());
      process = await Process.start(executable.path, [root.path]);
      unawaited(process!.stdout.drain<void>());
      unawaited(process!.stderr.drain<void>());
      await waitEvent('started');
      await command('install');
    }

    const info = AppUpdateInfo(
        currentVersion: '0.0.0.100',
        currentBuildNumber: '100',
        latestVersion: '0.0.0.101',
        latestBuildNumber: '101',
        isUpdateAvailable: true);
    final remoteFeed = Uri.parse('https://fixture.invalid/feed');
    expect(await installedBuild(), '100');

    Future<void> completeInstallation(
        DesktopUpdateCache instance,
        CachedDesktopUpdate downloaded,
        FixtureAdapter adapter,
        int expectedDownloads) async {
      final restored = await instance.download(info, remoteFeed);
      expect(restored.archive.path, downloaded.archive.path);
      expect(adapter.downloads, expectedDownloads);
      stderr.writeln(
          'ACTION: Complete the EasyO Update Verification installer (Install, then Finish).');
      await launch(await instance.installationFeed(restored));
      await waitEvent('installerLaunched');
      // Explicitly close only the fixture so Inno can replace its executable.
      await quit();
      await waitFor(
          () async => await installerResult.exists(), 'complete installer');
      expect(await installerResult.readAsString(), 'installed');
      expect(await installedBuild(), '101');
      process = await Process.start(executable.path, [root.path]);
      unawaited(process!.stdout.drain<void>());
      unawaited(process!.stderr.drain<void>());
      await waitFor(
          () async => (await events.readAsLines()).any((line) =>
              line.contains('"event":"started"') &&
              line.contains('"build":"101"')),
          'launch installed build 101');
      await quit();
      expect(await instance.restore(), isNull);
      expect(await downloaded.archive.exists(), isFalse);
      expect(adapter.downloads, expectedDownloads);
      stderr.writeln(
          'PASS: EXE build 101 installed and launched; cache cleaned; remote downloads this run: $expectedDownloads.');
    }

    if (Platform.environment['EASYO_VERIFY_INSTALL_ONLY'] == '1') {
      final adapter = FixtureAdapter(root)..offline = true;
      final instance = cache(adapter);
      final retained = await instance.restore();
      expect(retained, isNotNull,
          reason: 'Requires retained cache from cancelled run');
      await completeInstallation(instance, retained!, adapter, 0);
      return;
    }

    // Prove native comparison uses build 100, rather than ProductVersion 0.0.0.
    for (final offeredBuild in ['100', '99']) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var packageRequests = 0;
      server.listen((request) async {
        if (request.uri.path == '/feed') {
          request.response.headers.contentType =
              ContentType('application', 'xml');
          request.response.write(
              '''<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Build comparison</title><item>
<sparkle:version>$offeredBuild</sparkle:version><sparkle:shortVersionString>0.0.0.$offeredBuild</sparkle:shortVersionString>
<enclosure url="http://127.0.0.1:${server.port}/package.exe" length="1" type="application/octet-stream" sparkle:edSignature="${base64Encode(List.filled(64, 1))}" />
</item></channel></rss>''');
        } else {
          packageRequests++;
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      try {
        await launch(Uri.parse('http://127.0.0.1:${server.port}/feed'));
        await waitEvent('notFound');
        expect(packageRequests, 0);
        await quit();
      } finally {
        await server.close(force: true);
      }
    }
    stderr.writeln(
        'PASS: native build 100 rejects same/older builds without package requests.');

    // Use a separately cached invalid signature to exercise actual native rejection.
    final rejected = cache(FixtureAdapter(root, reject: true));
    final bad = await rejected.download(info, remoteFeed);
    await launch(await rejected.installationFeed(bad));
    await waitEvent('failed');
    expect(await installedBuild(), '100');
    expect(await rejected.restore(), isNotNull);
    await quit();
    await rejected.close();
    stderr.writeln(
        'PASS: real WinSparkle rejected bad signature; cache retained.');

    final adapter = FixtureAdapter(root);
    var instance = cache(adapter);
    final downloaded = await instance.download(info, remoteFeed);
    await instance.close();
    adapter.offline = true;
    instance = cache(adapter);
    final restored = await instance.download(info, remoteFeed);
    expect(restored.archive.path, downloaded.archive.path);
    expect(adapter.downloads, 1);
    stderr.writeln(
        'ACTION: In the EasyO Update Verification installer, click Cancel and confirm.');
    await launch(await instance.installationFeed(restored));
    await waitEvent('installerLaunched');
    await waitFor(
        () async => await installerResult.exists(), 'cancel installer');
    expect(await installerResult.readAsString(), 'cancelled');
    expect(await installedBuild(), '100');
    expect(await instance.restore(), isNotNull);
    await quit();
    await instance.close();
    stderr.writeln(
        'PASS: cancelled installer retained build 100 and complete package.');

    await completeInstallation(cache(adapter), downloaded, adapter, 1);
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 18)));
}
