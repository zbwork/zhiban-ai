import 'dart:async';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexwork/layout/widgets/sidebar_profile_popover.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/pages/settings/settings_page.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_cache.dart';
import 'package:zhiban_client/services/desktop_update_service.dart';
import 'package:zhiban_client/widgets/ui/desktop_update_check_feedback.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _available = AppUpdateInfo(
    currentVersion: '1.4.0',
    currentBuildNumber: '14001',
    latestVersion: '1.4.1',
    latestBuildNumber: '14100',
    isUpdateAvailable: true);
const _current = AppUpdateInfo(
    currentVersion: '1.4.1',
    currentBuildNumber: '14100',
    latestVersion: '1.4.1',
    latestBuildNumber: '14100',
    isUpdateAvailable: false);

class _PendingCache extends DesktopUpdateCache {
  _PendingCache()
      : super(
            platform: 'macos',
            directory: () async => Directory.systemTemp,
            installedBuild: () async => '14001');
  // Create the future in the widget test's error zone, like a real download.
  late final downloadResult = Completer<CachedDesktopUpdate>();
  DesktopDownloadProgressCallback? progress;

  @override
  bool get isDownloading => progress != null && !downloadResult.isCompleted;

  @override
  Future<CachedDesktopUpdate?> restore({String latestBuild = ''}) async => null;

  @override
  Future<CachedDesktopUpdate> download(AppUpdateInfo info, Uri feedUrl,
      {DesktopDownloadProgressCallback? onProgress}) {
    progress = onProgress;
    return downloadResult.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.qkfintech.zhiban/update');
  late _PendingCache cache;
  setUp(() {
    cache = _PendingCache();
    PackageInfo.setMockInitialValues(
        appName: '知办AI',
        packageName: 'test',
        version: '1.4.0',
        buildNumber: '14001',
        buildSignature: '');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (_) async => {
                  'pendingInstall': false,
                  'canCheckForUpdates': true,
                });
  });
  tearDown(() async {
    await cache.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('about shows live progress while the check Future is pending',
      (tester) async {
    final query = Completer<AppUpdateInfo?>();
    await DesktopUpdateService.configureForTesting(
        cache: cache, fetchInfo: () => query.future);
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        MaterialApp(builder: BotToastInit(), home: const AboutPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.text('检查中'), findsOneWidget);
    query.complete(_available);
    await tester.pump();
    cache.progress!(11, 100, packageType: 'full');
    await tester.pump();
    expect(find.text('下载中 11%'), findsOneWidget);
    expect(find.text('检查中'), findsNothing);
    expect(cache.downloadResult.isCompleted, isFalse);

    // Reopening restores ongoing work without starting another check.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        MaterialApp(builder: BotToastInit(), home: const AboutPage()));
    await tester.pumpAndSettle();
    expect(find.text('下载中'), findsOneWidget);
    cache.progress!(12, 100, packageType: 'full');
    await tester.pumpAndSettle();
    expect(find.text('下载中 12%'), findsOneWidget);
    // Closing releases the subscriber without cancelling download.
    await tester.pumpWidget(const SizedBox());
    cache.downloadResult.completeError(StateError('test download failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('about ends an up-to-date check with explicit feedback',
      (tester) async {
    await DesktopUpdateService.configureForTesting(
        cache: cache, fetchInfo: () async => _current);
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        MaterialApp(builder: BotToastInit(), home: const AboutPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('检查中'), findsNothing);
    expect(find.text('已是最新版本'), findsWidgets);
    expect(cache.progress, isNull);
    BotToast.cleanAll();
    await tester.pumpAndSettle();
  });

  test('stale snapshot and check completion cannot erase live download', () {
    final feedback = DesktopUpdateCheckFeedback();
    final revision = feedback.begin();
    feedback.accept(
        {'event': 'downloadProgress', 'receivedBytes': 11, 'totalBytes': 100});
    feedback.restore(
        const DesktopUpdateState(
            pendingInstall: false,
            pendingBuildNumber: '',
            canCheckForUpdates: true),
        ifUnchanged: revision);
    feedback.complete(DesktopUpdateCheckResult.failed, ifUnchanged: revision);
    expect(feedback.label, '下载中 11%');
    expect(feedback.busy, isTrue);
    feedback.accept({'event': 'downloadComplete'});
    expect(feedback.label, '已下载');
    expect(feedback.busy, isFalse);
  });

  testWidgets(
      'profile menu reports start before query and result after completion',
      (tester) async {
    final query = Completer<AppUpdateInfo?>();
    await DesktopUpdateService.configureForTesting(
        cache: cache, fetchInfo: () => query.future);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      builder: BotToastInit(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => Dialog(
                              child: SidebarProfilePopover(
                                  info: null,
                                  hostContext: context,
                                  initialMe:
                                      const MeResult(account: {}, scopes: []),
                                  loadCurrentTenantId: () async => 0,
                                  localCodingToolsAvailable: false),
                            )),
                    child: const Text('打开菜单'),
                  ))),
    )));
    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('正在检查更新'), findsOneWidget);
    expect(query.isCompleted, isFalse);
    query.complete(_current);
    await tester.pumpAndSettle();
    expect(find.text('已是最新版本'), findsOneWidget);
    BotToast.cleanAll();
    await tester.pumpAndSettle();
  });

  test('typed concurrent checks share download and identify native outcomes',
      () async {
    var fetches = 0;
    final coordinator = DesktopUpdateCoordinator(
        cache: cache,
        fetchInfo: () async {
          fetches++;
          return _available;
        });
    final first = coordinator.checkForUpdates();
    final second = coordinator.checkForUpdates();
    expect(identical(first, second), isTrue);
    cache.downloadResult.complete(CachedDesktopUpdate(
        directory: Directory.systemTemp,
        buildNumber: '14100',
        version: '1.4.1',
        platform: 'macos',
        size: 100,
        digest: '',
        appcast: ''));
    expect(await first, DesktopUpdateCheckResult.downloaded);
    expect(await second, DesktopUpdateCheckResult.downloaded);
    expect(fetches, 1);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        channel, (_) async => {'pendingInstall': true});
    expect(await coordinator.checkForUpdates(),
        DesktopUpdateCheckResult.readyToRestart);
    messenger.setMockMethodCallHandler(
        channel, (_) async => {'sessionInProgress': true});
    expect(await coordinator.checkForUpdates(),
        DesktopUpdateCheckResult.installing);
    expect(fetches, 1);
  });

  test('reopened page restores download and distinguishes native readiness',
      () {
    final feedback = DesktopUpdateCheckFeedback();
    feedback.restore(
        const DesktopUpdateState(
            pendingInstall: false,
            pendingBuildNumber: '',
            canCheckForUpdates: false,
            downloading: true),
        ifUnchanged: feedback.revision);
    expect(feedback.label, '下载中');
    feedback.accept({'event': 'installPreparing'});
    expect(feedback.label, '准备安装中');
    feedback.accept({'event': 'installReady'});
    expect(feedback.label, '安装已就绪');
    expect(feedback.busy, isFalse);
  });

  test('observer opened during a failing query receives a terminal event',
      () async {
    final query = Completer<AppUpdateInfo?>();
    final coordinator =
        DesktopUpdateCoordinator(cache: cache, fetchInfo: () => query.future);
    final feedback = DesktopUpdateCheckFeedback();
    final subscription = coordinator.updateEvents.listen(feedback.accept);
    addTearDown(subscription.cancel);
    final check = coordinator.checkForUpdates();
    await Future<void>.delayed(Duration.zero);
    final snapshot = await coordinator.getUpdateState();
    expect(snapshot.checking, isTrue);
    expect(snapshot.downloading, isFalse);
    feedback.restore(snapshot, ifUnchanged: feedback.revision);
    expect(feedback.label, '检查中');
    query.completeError(StateError('query failed'));
    expect(await check, DesktopUpdateCheckResult.failed);
    await Future<void>.delayed(Duration.zero);
    expect(feedback.busy, isFalse);
    expect(feedback.label, '检查或下载失败');
  });

  test('query failure ends checking and a retry can return up-to-date',
      () async {
    var fail = true;
    final coordinator = DesktopUpdateCoordinator(
        cache: cache, fetchInfo: () async => fail ? null : _current);
    final feedback = DesktopUpdateCheckFeedback();
    var revision = feedback.begin();
    final failed = await coordinator.checkForUpdates();
    feedback.complete(failed, ifUnchanged: revision);
    expect(failed, DesktopUpdateCheckResult.failed);
    expect(feedback.busy, isFalse);
    expect(feedback.label, '检查或下载失败');
    fail = false;
    revision = feedback.begin();
    final result = await coordinator.checkForUpdates();
    feedback.complete(result, ifUnchanged: revision);
    expect(result.message, '已是最新版本');
    expect(feedback.label, '已是最新版本');
  });
}
