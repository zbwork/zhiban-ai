import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/layout/widgets/sidebar_update_controller.dart';
import 'package:nexwork/layout/widgets/sidebar_update_indicator.dart';
import 'package:zhiban_client/services/desktop_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cn.qkfintech.zhiban/update');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('all install entrypoints share one native handoff', () async {
    final pending = Completer<bool>();
    var installs = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getUpdateState') return {'pendingInstall': true};
      installs++;
      return pending.future;
    });
    final coordinator = DesktopUpdateCoordinator();
    final first = coordinator.installPendingUpdate();
    final second = coordinator.installUpdateInBackground();
    expect(identical(first, second), isTrue);
    pending.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(installs, 1);
  });

  test('active native session suppresses new downloads and handoffs', () async {
    var fetches = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getUpdateState');
      return {'pendingInstall': false, 'sessionInProgress': true};
    });
    final coordinator = DesktopUpdateCoordinator(fetchInfo: () async {
      fetches++;
      return null;
    });
    expect(await coordinator.checkAndDownloadUpdate(), isTrue);
    expect(await coordinator.installUpdateInBackground(), isTrue);
    expect((await coordinator.getUpdateState()).nativeSessionActive, isTrue);
    expect(fetches, 0);
  });

  test('restored cache does not imply native restart readiness', () {
    final controller = SidebarUpdateController();
    controller.restoreSnapshot(
        pendingInstall: false,
        downloading: false,
        cacheReady: true,
        buildNumber: '12500');
    expect(controller.stage, SidebarUpdateState.downloaded);
    expect(controller.claimRestartPrompt(), isFalse);
  });

  test('getUpdateState restores a pending native installation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getUpdateState');
      return <String, dynamic>{
        'pendingInstall': true,
        'canCheckForUpdates': false,
      };
    });

    final state = await DesktopUpdateService.getUpdateState();

    expect(state.pendingInstall, isTrue);
    expect(state.canCheckForUpdates, isFalse);
  });

  test('unavailable local storage does not launch an update', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    final launched = await DesktopUpdateService.checkAndDownloadUpdate();

    expect(launched, isFalse);
  });

  test('pending install remains visible when server refresh has no update', () {
    final state = SidebarUpdateController();

    state.restorePendingInstall('100');
    state.applyServerUpdateAvailability(false);

    expect(state.hasUpdate, isTrue);
    expect(state.isDownloaded, isTrue);
  });

  test('failed background cycle hides the sidebar prompt', () {
    final state = SidebarUpdateController()
      ..applyServerUpdateAvailability(true)
      ..markDownloadStarted('100');

    state.markDownloadFailed();

    expect(state.isBusy, isFalse);
    expect(state.hasUpdate, isFalse);
    expect(state.canStartDownload, isFalse);
  });

  test('download progress is retained as a bounded fraction', () {
    final state = SidebarUpdateController()..markDownloadStarted('100');

    state.markDownloadProgress(25, 100);
    expect(state.progress, 0.25);

    state.markDownloadProgress(150, 100);
    expect(state.progress, 1);

    state.markDownloadProgress(50, 0);
    expect(state.progress, isNull);
  });

  test('preparing does not display completed download progress', () {
    final state = SidebarUpdateController()..restorePendingInstall('100');

    state.markChecking(true);

    expect(state.stage, SidebarUpdateState.preparing);
    expect(state.progress, isNull);
  });
}
