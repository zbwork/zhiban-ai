import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/android_update_service.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/widgets/ui/update_dialog.dart';

const _info = AppUpdateInfo(
  currentVersion: '1.0.0',
  currentBuildNumber: '100',
  latestVersion: '1.1.0',
  latestBuildNumber: '110',
  isUpdateAvailable: true,
  downloadUrl: 'https://example.com/update.apk',
);
const _forcedInfo = AppUpdateInfo(
  currentVersion: '1.0.0',
  currentBuildNumber: '100',
  latestVersion: '1.1.0',
  latestBuildNumber: '110',
  isUpdateAvailable: true,
  isForced: true,
  downloadUrl: 'https://example.com/update.apk',
);

AndroidUpdateDownload _download({
  AndroidDownloadStatus status = AndroidDownloadStatus.running,
  int id = 42,
  int bytes = 40,
  int total = 100,
  AppUpdateInfo info = _info,
}) =>
    AndroidUpdateDownload(
      status: status,
      downloadId: id,
      info: info,
      receivedBytes: bytes,
      totalBytes: total,
      message:
          status == AndroidDownloadStatus.failed ? '存储空间不足，请清理空间后重试下载' : '',
    );

class _Client extends AndroidUpdateClient {
  AndroidUpdateDownload download = _download();
  Future<AndroidUpdateDownload> Function()? onQuery;
  String installResult = 'launched';
  bool invalidPackage = false;
  final calls = <String>[];

  @override
  Future<AndroidUpdateDownload> query() async {
    calls.add('query');
    return onQuery == null ? download : await onQuery!();
  }

  @override
  Future<AndroidUpdateDownload> start(AppUpdateInfo info) async {
    calls.add('start');
    return download;
  }

  @override
  Future<AndroidUpdateDownload> retry(int id) async {
    calls.add('retry:$id');
    download = _download(id: id + 1, bytes: 0);
    return download;
  }

  @override
  Future<String> install(int id) async {
    calls.add('install:$id');
    if (invalidPackage) {
      download = _download(status: AndroidDownloadStatus.failed);
      throw PlatformException(code: 'invalid_package', message: '安装包无法识别');
    }
    return installResult;
  }
}

ProviderContainer _container(_Client client, {DateTime Function()? clock}) {
  final container = ProviderContainer(overrides: [
    androidUpdateClientProvider.overrideWithValue(client),
    if (clock != null) androidUpdateClockProvider.overrideWithValue(clock),
  ]);
  // Unit tests query explicitly; the lifecycle polling test enables its timer.
  container.read(androidUpdateProvider.notifier).setForeground(false);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recreating provider restores the same native task and bytes', () async {
    final client = _Client();
    final first = _container(client);
    await first.read(androidUpdateProvider.notifier).start(_info);
    first.dispose();

    final restored = _container(client);
    addTearDown(restored.dispose);
    await restored.read(androidUpdateProvider.notifier).refresh();
    expect(restored.read(androidUpdateProvider).download.downloadId, 42);
    expect(restored.read(androidUpdateProvider).download.receivedBytes, 40);
    expect(client.calls, ['start', 'query']);
  });

  test('stalled progress only shows a notice; waiting queries the same ID',
      () async {
    var now = DateTime(2026, 9, 8);
    final client = _Client();
    final container = _container(client, clock: () => now);
    addTearDown(container.dispose);
    final controller = container.read(androidUpdateProvider.notifier);
    await controller.refresh();
    now = now.add(const Duration(seconds: 31));
    await controller.refresh();
    expect(container.read(androidUpdateProvider).stalled, isTrue);
    expect(container.read(androidUpdateProvider).download.receivedBytes, 40);

    await controller.continueWaiting();
    expect(container.read(androidUpdateProvider).stalled, isFalse);
    expect(container.read(androidUpdateProvider).download.downloadId, 42);
    expect(client.calls, ['query', 'query', 'query']);
  });

  test('network waiting cannot retry or replace a resumable task', () async {
    final client = _Client()
      ..download = _download(status: AndroidDownloadStatus.waiting);
    final container = _container(client);
    addTearDown(container.dispose);
    final controller = container.read(androidUpdateProvider.notifier);
    await controller.refresh();
    await controller.retry();
    expect(container.read(androidUpdateProvider).label, '更新正在等待网络');
    expect(client.calls, ['query', 'query']);
    client.download =
        _download(status: AndroidDownloadStatus.ready, bytes: 100);
    await controller.refresh();
    expect(container.read(androidUpdateProvider).download.downloadId, 42);
    expect(container.read(androidUpdateProvider).download.progress, 1);
  });

  test('query timeout retains progress and allows waiting again', () async {
    final client = _Client();
    final container = _container(client);
    addTearDown(container.dispose);
    final controller = container.read(androidUpdateProvider.notifier);
    await controller.refresh();
    client.onQuery = () => Future.error(TimeoutException('native query'));
    await controller.refresh();
    final state = container.read(androidUpdateProvider);
    expect(state.download.downloadId, 42);
    expect(state.download.receivedBytes, 40);
    expect(state.notice, '暂时无法读取进度，下载任务仍保留');
    client.onQuery = null;
    client.download = _download(bytes: 60);
    await controller.continueWaiting();
    expect(container.read(androidUpdateProvider).download.receivedBytes, 60);
    expect(client.calls, everyElement('query'));
  });

  test('terminal failure only creates a replacement on explicit retry',
      () async {
    final client = _Client()
      ..download = _download(status: AndroidDownloadStatus.failed);
    final container = _container(client);
    addTearDown(container.dispose);
    final controller = container.read(androidUpdateProvider.notifier);
    await controller.refresh();
    await controller.continueWaiting();
    expect(client.calls, ['query', 'query']);
    await controller.retry();
    expect(client.calls.last, 'retry:42');
    expect(container.read(androidUpdateProvider).download.downloadId, 43);
  });

  for (final result in ['permissionRequired', 'launched']) {
    test('$result retains ready APK for a second install attempt', () async {
      final client = _Client()
        ..download = _download(status: AndroidDownloadStatus.ready, bytes: 100)
        ..installResult = result;
      final container = _container(client);
      addTearDown(container.dispose);
      final controller = container.read(androidUpdateProvider.notifier);
      await controller.refresh();
      await controller.install();
      expect(container.read(androidUpdateProvider).download.status,
          AndroidDownloadStatus.ready);
      expect(container.read(androidUpdateProvider).notice, isNotEmpty);
      await controller.install();
      expect(client.calls, ['query', 'install:42', 'install:42']);
    });
  }

  test('invalid APK changes install action to explicit download retry',
      () async {
    final client = _Client()
      ..download = _download(status: AndroidDownloadStatus.ready, bytes: 100)
      ..invalidPackage = true;
    final container = _container(client);
    addTearDown(container.dispose);
    final controller = container.read(androidUpdateProvider.notifier);
    await controller.refresh();
    await controller.install();
    expect(container.read(androidUpdateProvider).download.status,
        AndroidDownloadStatus.failed);
    expect(client.calls, ['query', 'install:42', 'query']);
    await controller.retry();
    expect(client.calls.last, 'retry:42');
  });

  for (final fails in [false, true]) {
    test(
        'late query ${fails ? 'error' : 'result'} cannot overwrite newer start',
        () async {
      final pending = Completer<AndroidUpdateDownload>();
      final client = _Client()..onQuery = () => pending.future;
      final container = _container(client);
      addTearDown(container.dispose);
      final controller = container.read(androidUpdateProvider.notifier);
      final query = controller.refresh();
      await controller.start(_info);
      if (fails) {
        pending.completeError(TimeoutException('old query'));
      } else {
        pending.complete(const AndroidUpdateDownload());
      }
      await query;
      final state = container.read(androidUpdateProvider);
      expect(state.download.downloadId, 42);
      expect(state.busy, isFalse);
      expect(state.notice, isNull);
    });
  }

  test('unknown total uses indeterminate progress', () {
    expect(_download(total: -1).progress, isNull);
    expect(_download(total: 0).progress, isNull);
    expect(_download(bytes: 120).progress, 1);
  });

  testWidgets(
      'background pauses queries only and resume refreshes native progress',
      (tester) async {
    final client = _Client();
    final container = _container(client);
    final controller = container.read(androidUpdateProvider.notifier);
    await controller.refresh();
    controller.setForeground(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final foregroundCalls = client.calls.length;
    expect(foregroundCalls, greaterThan(2));
    controller.setForeground(false);
    await tester.pump(const Duration(seconds: 40));
    expect(client.calls.length, foregroundCalls);
    client.download =
        _download(status: AndroidDownloadStatus.ready, bytes: 100);
    controller.setForeground(true);
    await tester.pump();
    expect(container.read(androidUpdateProvider).download.status,
        AndroidDownloadStatus.ready);
    expect(client.calls, everyElement('query'));
    container.dispose();
  });

  testWidgets('minimize and reopen keeps progress without another start',
      (tester) async {
    final client = _Client();
    final container = _container(client);
    await container.read(androidUpdateProvider.notifier).refresh();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child:
          const MaterialApp(home: Scaffold(body: AndroidUpdateProgressEntry())),
    ));
    await tester.tap(find.text('更新下载中 40%'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AndroidUpdateDialog), findsOneWidget);
    await tester.tap(find.text('最小化'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AndroidUpdateDialog), findsNothing);
    client.download = _download(bytes: 65);
    await container.read(androidUpdateProvider.notifier).refresh();
    await tester.pump();
    await tester.tap(find.text('更新下载中 65%'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AndroidUpdateDialog), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        .65);
    expect(find.text('继续等待'), findsNothing);
    expect(find.text('重试下载'), findsNothing);
    expect(client.calls, everyElement('query'));
    await tester.tap(find.text('最小化'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('forced update has no minimize entry and blocks back',
      (tester) async {
    final client = _Client()..download = _download(info: _forcedInfo);
    final container = _container(client);
    await container.read(androidUpdateProvider.notifier).refresh();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => Column(children: [
                        const AndroidUpdateProgressEntry(),
                        TextButton(
                            onPressed: () => showAndroidUpdateAvailableDialog(
                                context, _forcedInfo),
                            child: const Text('更新')),
                      ],),
    ),
          ),
        ),
      ),
    );
    expect(find.text('更新下载中 40%'), findsNothing);
    await tester.tap(find.text('更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('最小化'), findsNothing);
    expect(find.text('稍后再说'), findsNothing);
    expect(find.text('继续等待'), findsNothing);
    expect(find.text('更新下载中 40%'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pump();
    expect(find.byType(AndroidUpdateDialog), findsOneWidget);
    // Explicit route cleanup in test only; real system back used maybePop above.
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets(
      'native channel restores serialized task and preserves version metadata',
      (tester) async {
    const channel = MethodChannel('cn.qkfintech.zhiban/android_update');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'status': 'waiting',
        'downloadId': 77,
        'receivedBytes': 200,
        'totalBytes': 1000,
        'message': '等待网络连接，恢复后将继续下载',
        'update': {
          'latestVersion': '1.1.0',
          'latestBuildNumber': '110',
          'downloadUrl': _info.downloadUrl,
          'isForced': true,
        },
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    const client = AndroidUpdateClient();
    final restored = await client.query();
    expect(restored.downloadId, 77);
    expect(restored.progress, .2);
    expect(restored.info!.isForced, isTrue);
    expect(restored.status, AndroidDownloadStatus.waiting);
    await client.start(_forcedInfo);
    expect(calls.last.method, 'start');
    expect((calls.last.arguments as Map)['update']['latestBuildNumber'], '110');
    expect((calls.last.arguments as Map)['update']['isForced'], isTrue);
  });
}
