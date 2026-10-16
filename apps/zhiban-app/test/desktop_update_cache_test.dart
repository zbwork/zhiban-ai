import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_client/services/desktop_update_service.dart';
import 'package:nexwork/layout/widgets/sidebar_update_controller.dart';
import 'package:nexwork/layout/widgets/sidebar_update_indicator.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_cache.dart';
import 'package:xml/xml.dart';

const info = AppUpdateInfo(
    currentVersion: '1.0',
    currentBuildNumber: '100',
    latestVersion: '1.1',
    latestBuildNumber: '110',
    isUpdateAvailable: true);
final feedUrl = Uri.parse('https://updates.example.com/appcast');
final signature = base64Encode(List<int>.filled(64, 1));

// Restore the SDK HttpClient only for this loopback transport test.
class _LoopbackHttpOverrides extends HttpOverrides {}

class _Adapter implements HttpClientAdapter {
  List<int> payload = List.generate(1024, (i) => i % 256);
  int requests = 0;
  final requestedUris = <Uri>[];
  String? size = '1024';
  bool interrupted = false;
  bool signed = true;
  bool offline = false;
  bool failDelta = false;
  String? deltaSignature = signature;
  Uri feedUri = feedUrl;
  String packageOrigin = 'https://example.com';
  String offeredBuild = '110';
  String offeredVersion = '1.1';

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (offline) throw const SocketException('offline');
    if (options.uri == feedUri) {
      return ResponseBody.fromString(
          '''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>999</sparkle:version><enclosure url="https://example.com/newer" /></item>
<item><sparkle:version>$offeredBuild</sparkle:version><sparkle:shortVersionString>$offeredVersion</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
<enclosure url="$packageOrigin/package" ${size == null ? '' : 'length="$size"'} ${signed ? 'sparkle:edSignature="$signature"' : ''} />
<sparkle:deltas><enclosure url="$packageOrigin/delta" sparkle:deltaFrom="100" ${size == null ? '' : 'length="$size"'} ${signed && deltaSignature != null ? 'sparkle:edSignature="$deltaSignature"' : ''} /></sparkle:deltas>
</item></channel></rss>''', 200);
    }
    requests++;
    requestedUris.add(options.uri);
    if (failDelta && options.uri.path == '/delta') {
      throw const SocketException('delta connection reset');
    }
    if (interrupted) {
      return ResponseBody(
          Stream<Uint8List>.error(const SocketException('connection reset')),
          200);
    }
    return ResponseBody.fromBytes(payload, 200, headers: {
      Headers.contentLengthHeader: ['${payload.length}'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in ['macos', 'windows']) {
    group(platform, () {
      late Directory directory;
      late _Adapter adapter;
      late String installed;
      final instances = <DesktopUpdateCache>[];

      DesktopUpdateCache cache() {
        final value = DesktopUpdateCache(
            platform: platform,
            directory: () async => directory,
            installedBuild: () async => installed,
            dio: Dio()..httpClientAdapter = adapter);
        instances.add(value);
        return value;
      }

      setUp(() async {
        directory =
            await Directory.systemTemp.createTemp('desktop-update-cache-test-');
        adapter = _Adapter();
        installed = '100';
      });
      tearDown(() async {
        for (final instance in instances) {
          await instance.close();
        }
        instances.clear();
        await directory.delete(recursive: true);
      });

      test(
          'check waits for preparation started by install and receives failure',
          () async {
        const channel = MethodChannel('cn.qkfintech.zhiban/update');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final checkEntered = Completer<void>();
        var reads = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getUpdateState');
          if (++reads == 2) checkEntered.complete();
          return {'pendingInstall': false};
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final fetchEntered = Completer<void>();
        final query = Completer<AppUpdateInfo?>();
        var fetches = 0;
        final coordinator = DesktopUpdateCoordinator(
            cache: cache(),
            fetchInfo: () {
              fetches++;
              fetchEntered.complete();
              return query.future;
            });
        final installation = coordinator.installUpdateInBackground();
        await fetchEntered.future;
        var finished = false;
        final check = coordinator.checkAndDownloadUpdate().then((value) {
          finished = true;
          return value;
        });
        await checkEntered.future;
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        query.completeError(StateError('query failed'));
        expect(await check, isFalse);
        expect(await installation, isFalse);
        expect(fetches, 1);
      });

      test('completed package survives service restart without remote requests',
          () async {
        final first = await cache().download(info, feedUrl);
        expect(adapter.requests, 1);
        adapter.offline = true;
        final second = await cache().download(info, feedUrl);
        expect(second.archive.path, first.archive.path);
        expect(await second.archive.readAsBytes(), adapter.payload);
        expect(adapter.requests, 1);
      });

      test('Debug allows local HTTP feed and package downloads', () async {
        adapter.feedUri = Uri.parse('http://localhost:8080/feed');
        adapter.packageOrigin = 'http://127.0.0.1:8080';
        final downloaded = await cache().download(info, adapter.feedUri);
        expect(await downloaded.archive.readAsBytes(), adapter.payload);
        expect(adapter.requestedUris.single.host, '127.0.0.1');
      });

      test('Debug still rejects remote HTTP packages', () async {
        adapter.packageOrigin = 'http://example.com';
        await expectLater(
            cache().download(info, feedUrl), throwsFormatException);
        expect(adapter.requests, 0);
      });

      test('higher server build replaces the completed cached package',
          () async {
        final first = await cache().download(info, feedUrl);
        adapter.offeredBuild = '120';
        adapter.offeredVersion = '1.2';
        const newer = AppUpdateInfo(
            currentVersion: '1.0',
            currentBuildNumber: '100',
            latestVersion: '1.2',
            latestBuildNumber: '120',
            isUpdateAvailable: true);
        final second = await cache().download(newer, feedUrl);
        expect(second.buildNumber, '120');
        expect(second.archive.path, isNot(first.archive.path));
        expect(await first.directory.exists(), isFalse);
        expect(adapter.requests, 2);
      });

      test('cached package that the server no longer offers is discarded',
          () async {
        // 2026-09-16:缓存里躺着已被取代(甚至已下线)的包时,旧逻辑只比"比已装
        // 版本新"就复用,用户永远升不上去,而且那个包装不上。
        final stale = await cache().download(info, feedUrl);
        expect(await stale.archive.exists(), isTrue);
        expect(await cache().restore(latestBuild: info.latestBuildNumber),
            isNotNull);

        final discarded = await cache().restore(latestBuild: '120');
        expect(discarded, isNull);
        expect(await stale.archive.exists(), isFalse);
      });

      test('cache is still usable when the latest build is unknown (offline)',
          () async {
        final cached = await cache().download(info, feedUrl);
        adapter.offline = true;
        final restored = await cache().restore();
        expect(restored, isNotNull);
        expect(restored!.archive.path, cached.archive.path);
      });

      test('concurrent requests share one completed package', () async {
        final instance = cache();
        final result = await Future.wait([
          instance.download(info, feedUrl),
          instance.download(info, feedUrl)
        ]);
        expect(result[0].archive.path, result[1].archive.path);
        expect(adapter.requests, 1);
      });

      test('download reports byte progress before publishing cache', () async {
        final progress = <(int, int)>[];
        await cache().download(info, feedUrl,
            onProgress: (received, total, {required packageType}) =>
                progress.add((received, total)));
        expect(progress, isNotEmpty);
        expect(progress.first, (0, 1024));
        expect(progress.last, (1024, 1024));
      });

      if (platform == 'macos') {
        test('state logs distinguish native pending from usable Delta cache',
            () async {
          final instance = cache();
          await instance.download(info, feedUrl);
          await DesktopUpdateService.configureForTesting(
              cache: instance, fetchInfo: () async => info);
          const channel = MethodChannel('cn.qkfintech.zhiban/update');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
              channel,
              (_) async => {
                    'pendingInstall': false,
                    'canCheckForUpdates': true,
                  });
          final messages = <String>[];
          final previousPrint = debugPrint;
          debugPrint = (message, {wrapWidth}) {
            if (message != null) messages.add(message);
          };
          try {
            expect((await DesktopUpdateService.getUpdateState()).pendingInstall,
                isTrue);
            await DesktopUpdateService.getUpdateState();
            expect(messages, hasLength(1));
            expect(messages.single, contains('native_pending=false'));
            expect(messages.single, contains('cache_state=ready'));
            expect(messages.single, contains('cache_package=delta'));
            expect(messages.single, contains('delta_from_build=100'));
            expect(messages.single, contains('target_build=110'));
            expect(messages.single, contains('ui_ready=true'));

            installed = '99';
            expect((await DesktopUpdateService.getUpdateState()).pendingInstall,
                isFalse);
            expect(messages, hasLength(2));
            expect(messages.last, contains('cache_state=unavailable'));
            expect(messages.last, contains('ui_ready=false'));
          } finally {
            debugPrint = previousPrint;
            messenger.setMockMethodCallHandler(channel, null);
          }
        });

        test('Delta from another installed build is not restored as ready',
            () async {
          final first = await cache().download(info, feedUrl);
          installed = '99';
          expect(await cache().restore(), isNull);
          expect(await first.archive.exists(), isTrue);

          final next = await cache().download(info, feedUrl);
          expect(next.packageType, 'full');
          expect(adapter.requestedUris, [
            Uri.parse('https://example.com/delta'),
            Uri.parse('https://example.com/package'),
          ]);
        });

        test('prioritizes the matching signed Delta package', () async {
          final update = await cache().download(info, feedUrl);

          expect(update.packageType, 'delta');
          expect(update.deltaFromBuild, '100');
          expect(update.filename, 'installer.delta');
          expect(
              adapter.requestedUris, [Uri.parse('https://example.com/delta')]);
        });

        test('uses the full package when no Delta matches the installed build',
            () async {
          installed = '99';
          final update = await cache().download(info, feedUrl);

          expect(update.packageType, 'full');
          expect(adapter.requestedUris,
              [Uri.parse('https://example.com/package')]);
        });

        test('falls back to full package when Delta download fails', () async {
          adapter.failDelta = true;
          final update = await cache().download(info, feedUrl);

          expect(update.packageType, 'full');
          expect(adapter.requestedUris, [
            Uri.parse('https://example.com/delta'),
            Uri.parse('https://example.com/package'),
          ]);
        });

        for (final invalidSignature in [null, 'not-base64!', 'AQ==']) {
          test('falls back when Delta signature is invalid: $invalidSignature',
              () async {
            adapter.deltaSignature = invalidSignature;
            final update = await cache().download(info, feedUrl);

            expect(update.packageType, 'full');
            expect(adapter.requestedUris,
                [Uri.parse('https://example.com/package')]);
          });
        }
      }

      test(
          'installer cancellation and no installed version change never delete package',
          () async {
        final first = await cache().download(info, feedUrl);
        final fresh = cache();
        final restored = await fresh.restore();
        await fresh.installationFeed(restored!);
        await fresh
            .close(); // Native installer may close its connection or user may quit.
        expect((await cache().restore())?.archive.path, first.archive.path);
        expect(await first.archive.exists(), isTrue);
      });

      test('only a confirmed installed build cleans completed package',
          () async {
        final first = await cache().download(info, feedUrl);
        installed = '109';
        expect(
            await cache().restore(), platform == 'macos' ? isNull : isNotNull);
        expect(await first.archive.exists(), isTrue);
        installed = '110';
        expect(await cache().restore(), isNull);
        expect(await first.directory.exists(), isFalse);
      });

      test('incomplete size never publishes a ready record', () async {
        adapter.size = '2048';
        await expectLater(
            cache().download(info, feedUrl), throwsFormatException);
        expect(await cache().restore(), isNull);
        expect(
            await directory
                .list(recursive: true)
                .where((e) => e.path.endsWith('manifest.json'))
                .toList(),
            isEmpty);
      });

      for (final declaredSize in ['0', null]) {
        test(
            'unknown length $declaredSize records actual size and restores offline',
            () async {
          adapter.size = declaredSize;
          final first = await cache().download(info, feedUrl);
          expect(first.size, adapter.payload.length);
          final item =
              XmlDocument.parse(first.appcast).findAllElements('item').single;
          final enclosure = platform == 'macos'
              ? item
                  .findAllElements('deltas',
                      namespace:
                          'http://www.andymatuschak.org/xml-namespaces/sparkle')
                  .expand((deltas) => deltas.findElements('enclosure'))
                  .single
              : item.getElement('enclosure')!;
          expect(enclosure.getAttribute('length'), '${adapter.payload.length}');
          expect(
              enclosure.getAttribute('edSignature',
                  namespace:
                      'http://www.andymatuschak.org/xml-namespaces/sparkle'),
              signature);
          adapter.offline = true;
          final restored = await cache().download(info, feedUrl);
          expect(restored.archive.path, first.archive.path);
          expect(restored.size, adapter.payload.length);
          expect(adapter.requests, 1);
        });
      }

      test('unknown length never publishes an empty or interrupted download',
          () async {
        adapter.size = '0';
        adapter.payload = [];
        await expectLater(
            cache().download(info, feedUrl), throwsFormatException);
        expect(await cache().restore(), isNull);
        adapter.interrupted = true;
        await expectLater(
            cache().download(info, feedUrl), throwsA(isA<DioException>()));
        expect(await cache().restore(), isNull);
      });

      for (final invalidSize in ['-1', 'invalid']) {
        test('invalid length $invalidSize is rejected before download',
            () async {
          adapter.size = invalidSize;
          await expectLater(
              cache().download(info, feedUrl), throwsFormatException);
          expect(adapter.requests, 0);
        });
      }

      test('corruption is detected and explicit download creates fresh record',
          () async {
        final first = await cache().download(info, feedUrl);
        await first.archive.writeAsBytes(List.filled(1024, 9));
        expect(await cache().restore(), isNull);
        expect(await first.archive.exists(), isTrue);
        final second = await cache().download(info, feedUrl);
        expect(second.archive.path, isNot(first.archive.path));
        expect(await second.archive.readAsBytes(), adapter.payload);
      });

      test('malformed sibling manifest does not hide a valid cached package',
          () async {
        final first = await cache().download(info, feedUrl);
        final broken = Directory.fromUri(
            directory.uri.resolve('00000000-0000-4000-8000-000000000000/'));
        await broken.create();
        await File.fromUri(broken.uri.resolve('manifest.json'))
            .writeAsString('{incomplete');
        adapter.offline = true;
        expect((await cache().restore())?.archive.path, first.archive.path);
        expect(adapter.requests, 1);
      });

      test(
          'service entrypoints use restored feed while offline, cancellation restores ready',
          () async {
        final instance = cache();
        final first = await instance.download(info, feedUrl);
        adapter.offline = true;
        var fetches = 0;
        await DesktopUpdateService.configureForTesting(
            cache: instance,
            fetchInfo: () async {
              fetches++;
              throw const SocketException('offline');
            });
        const channel = MethodChannel('cn.qkfintech.zhiban/update');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getUpdateState') {
            return {'pendingInstall': false, 'canCheckForUpdates': true};
          }
          return true;
        });
        addTearDown(() => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null));
        expect((await DesktopUpdateService.getUpdateState()).pendingBuildNumber,
            '110');
        expect(await DesktopUpdateService.checkAndDownloadUpdate(), isTrue);
        expect(await DesktopUpdateService.installPendingUpdate(), isTrue);
        // Installing a completed cache must not query the server or download
        // the package again.
        expect(fetches, 1);
        expect(adapter.requests, 1);
        for (final call in calls.where((c) => c.method != 'getUpdateState')) {
          final url = Uri.parse((call.arguments as Map)['feedUrl'] as String);
          expect(url.host, '127.0.0.1');
        }
        DesktopUpdateService.registerUpdateEventHandler();
        final restored = DesktopUpdateService.updateEvents
            .firstWhere((event) => event['event'] == 'downloadComplete');
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('updateEvent', {'event': 'cancelled'})),
          (_) {},
        );
        expect((await restored)['buildNumber'], '110');
        expect(await first.archive.exists(), isTrue);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => null);
        // A completed persistent package can still be checked/restored without
        // a native menu check. Installation, however, requires the native handoff.
        expect(await DesktopUpdateService.checkAndDownloadUpdate(), isTrue);
        expect(await DesktopUpdateService.installPendingUpdate(), isFalse);
        expect(adapter.requests, 1);
      });

      test('service shares preparation across manual and background requests',
          () async {
        final release = Completer<AppUpdateInfo?>();
        var fetches = 0;
        await DesktopUpdateService.configureForTesting(
            cache: cache(),
            fetchInfo: () {
              fetches++;
              return release.future;
            });
        final first = DesktopUpdateService.checkAndDownloadUpdate(
            feedUrl: feedUrl.toString());
        final second = DesktopUpdateService.checkAndDownloadUpdate(
            feedUrl: feedUrl.toString());
        await Future<void>.delayed(Duration.zero);
        const channel = MethodChannel('cn.qkfintech.zhiban/update');
        final interactiveCalls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getUpdateState') {
            interactiveCalls.add(call.method);
          }
          return {'pendingInstall': false, 'canCheckForUpdates': true};
        });
        addTearDown(() => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null));
        final third = DesktopUpdateService.checkAndDownloadUpdate();
        expect(interactiveCalls, isEmpty);
        release.complete(info);
        expect(await Future.wait([first, second, third]), [true, true, true]);
        expect(fetches, 1);
        expect(adapter.requests, 1);
      });

      test('unsigned appcast is rejected before downloading', () async {
        adapter.signed = false;
        await expectLater(
            cache().download(info, feedUrl), throwsFormatException);
        expect(adapter.requests, 0);
      });

      test(
          'loopback feed preserves signature and system requirements, serves only package',
          () async {
        final instance = cache();
        final package = await instance.download(info, feedUrl);
        final urls = await Future.wait([
          instance.installationFeed(package),
          instance.installationFeed(package),
        ]);
        expect(urls[0], urls[1]);
        final url = urls[0];
        expect(url.host, '127.0.0.1');
        final http = HttpOverrides.runWithHttpOverrides(
            HttpClient.new, _LoopbackHttpOverrides());
        addTearDown(() => http.close(force: true));
        final response = await (await http.getUrl(url)).close();
        final document =
            XmlDocument.parse(await utf8.decoder.bind(response).join());
        final item = document.findAllElements('item').single;
        final enclosure = item.getElement('enclosure')!;
        expect(
            enclosure.getAttribute('edSignature',
                namespace:
                    'http://www.andymatuschak.org/xml-namespaces/sparkle'),
            signature);
        expect(document.findAllElements('item').length, 1);
        expect(
            document.findAllElements('deltas',
                namespace:
                    'http://www.andymatuschak.org/xml-namespaces/sparkle'),
            hasLength(1));
        expect(
            document
                .findAllElements('minimumSystemVersion',
                    namespace:
                        'http://www.andymatuschak.org/xml-namespaces/sparkle')
                .single
                .innerText,
            '11.0');
        final cachedEnclosure = platform == 'macos'
            ? item
                .findAllElements('deltas',
                    namespace:
                        'http://www.andymatuschak.org/xml-namespaces/sparkle')
                .expand((deltas) => deltas.findElements('enclosure'))
                .single
            : enclosure;
        final archiveUrl = Uri.parse(cachedEnclosure.getAttribute('url')!);
        final full = await (await http.getUrl(archiveUrl)).close();
        final bytes = await full.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(bytes, adapter.payload);
        final head = await (await http.headUrl(archiveUrl)).close();
        expect(head.contentLength, 1024);
        expect(
            await head.fold<int>(0, (size, bytes) => size + bytes.length), 0);
        final rangeRequest = await http.getUrl(archiveUrl);
        rangeRequest.headers.set('range', 'bytes=5-9');
        final range = await rangeRequest.close();
        expect(range.statusCode, 206);
        expect(await range.fold<List<int>>([], (a, b) => a..addAll(b)),
            adapter.payload.sublist(5, 10));
        final missing =
            await (await http.getUrl(url.replace(path: '/installer.exe')))
                .close();
        expect(missing.statusCode, 404);
        await missing.drain<void>();
        expect(adapter.requests, 1);
      });
    });
  }

  test('check completion cannot overwrite a download completion event', () {
    final state = SidebarUpdateController()..markChecking(true);
    state.markDownloadComplete(buildNumber: '110');
    state.markChecking(false);
    expect(state.isDownloaded, isTrue);
  });

  test('newer server release cannot replace an already prepared install', () {
    final state = SidebarUpdateController()..restorePendingInstall('110');
    state.applyServerUpdateAvailability(true, latestBuildNumber: '120');
    expect(state.stage, SidebarUpdateState.readyToRestart);
    expect(state.canStartDownload, isFalse);
    expect(state.pendingBuildNumber, '110');
  });
}
