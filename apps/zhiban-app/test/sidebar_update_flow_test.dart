import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/layout/widgets/sidebar_update_controller.dart';
import 'package:nexwork/layout/widgets/sidebar_update_event.dart';
import 'package:nexwork/layout/widgets/sidebar_update_install_command.dart';
import 'package:nexwork/layout/widgets/sidebar_update_state.dart';

void main() {
  late SidebarUpdateController controller;
  setUp(() => controller = SidebarUpdateController());

  SidebarUpdateInstallCommand command(Future<bool> Function() install) =>
      SidebarUpdateInstallCommand(
          controller: controller,
          install: install,
          onChanged: (change) => change());

  test('native fallback sequence drives download progress then preparation',
      () {
    void event(Map<String, dynamic> value) =>
        controller.accept(SidebarUpdateEvent.fromMap(value)!);
    event({'event': 'downloadComplete', 'buildNumber': '12500'});
    expect(controller.primaryAction, SidebarUpdateAction.prepare);
    event({'event': 'installPreparing'});
    event({'event': 'sparkleDownloadStarted', 'packageType': 'full'});
    event(
        {'event': 'downloadProgress', 'receivedBytes': 25, 'totalBytes': 100});
    expect(controller.stage, SidebarUpdateState.downloadingFull);
    expect(controller.progress, .25);
    expect(controller.primaryAction, SidebarUpdateAction.none);
    event({'event': 'sparkleDownloadComplete', 'packageType': 'full'});
    expect(controller.stage, SidebarUpdateState.preparing);
    event({'event': 'installReady', 'buildNumber': '12500'});
    expect(controller.primaryAction, SidebarUpdateAction.restart);
  });

  test('unknown events and malformed progress do not mutate state', () {
    expect(SidebarUpdateEvent.fromMap({'event': 'futureEvent'}), isNull);
    controller.markDownloadStarted('12500');
    controller.markDownloadProgress(25, 100);
    final before = controller.snapshot;
    controller.accept(SidebarUpdateEvent.fromMap({
      'event': 'downloadProgress',
      'receivedBytes': 'invalid',
      'totalBytes': 100,
    })!);
    expect(controller.snapshot, before);
  });

  test('prompt is once per build and never consumed before ready', () {
    expect(controller.claimRestartPrompt(), isFalse);
    controller.markInstallReady(buildNumber: '12500');
    expect(controller.claimRestartPrompt(), isTrue);
    controller.restorePendingInstall('12500');
    expect(controller.claimRestartPrompt(), isFalse);
    controller.markInstallReady(buildNumber: '12600');
    expect(controller.claimRestartPrompt(), isTrue);
  });

  test('restart is direct and concurrent clicks invoke native once', () async {
    controller.markInstallReady(buildNumber: '12500');
    final pending = Completer<bool>();
    var calls = 0;
    final install = command(() {
      calls++;
      return pending.future;
    });
    final first = install.execute();
    expect(controller.stage, SidebarUpdateState.installing);
    expect(await install.execute(), UpdateInstallResult.ignored);
    pending.complete(true);
    expect(await first, UpdateInstallResult.launched);
    expect(calls, 1);
  });

  for (final throwsError in [false, true]) {
    for (final restart in [false, true]) {
      test('failure recovery: restart=$restart throws=$throwsError', () async {
        if (restart) {
          controller.markInstallReady(buildNumber: '12500');
        } else {
          controller.markDownloadComplete(buildNumber: '12500');
        }
        final install = command(() async {
          if (throwsError) throw StateError('transport failure');
          return false;
        });
        expect(await install.execute(), UpdateInstallResult.failed);
        expect(
            controller.primaryAction,
            restart
                ? SidebarUpdateAction.restart
                : SidebarUpdateAction.prepare);
        expect(controller.pendingBuildNumber, '12500');
        expect(await install.execute(), UpdateInstallResult.failed);
      });
    }
  }

  test('late failed preparation cannot overwrite native installReady',
      () async {
    controller.markDownloadComplete(buildNumber: '12500');
    final pending = Completer<bool>();
    final operation = command(() => pending.future).execute();
    controller.markInstallReady(buildNumber: '12500');
    pending.complete(false);
    expect(await operation, UpdateInstallResult.ignored);
    expect(controller.stage, SidebarUpdateState.readyToRestart);
  });

  test('idle or downloading states cannot invoke install', () async {
    var calls = 0;
    final install = command(() async {
      calls++;
      return true;
    });
    expect(await install.execute(), UpdateInstallResult.ignored);
    controller.markDownloadStarted('12500');
    expect(await install.execute(), UpdateInstallResult.ignored);
    expect(calls, 0);
  });

  for (final throwsError in [false, true]) {
    test('progress does not swallow installation failure: throws=$throwsError',
        () async {
      controller.markDownloadComplete(buildNumber: '12500');
      final pending = Completer<bool>();
      final operation = command(() => pending.future).execute();
      controller.markInstallPreparing(preparationProgress: .5);
      if (throwsError) {
        pending.completeError(StateError('transport failed'));
      } else {
        pending.complete(false);
      }
      expect(await operation, UpdateInstallResult.failed);
      expect(controller.primaryAction, SidebarUpdateAction.prepare);
    });
  }

  test('failure preserves newer build and native full download', () async {
    for (final newBuild in [false, true]) {
      controller.markDownloadComplete(buildNumber: '12500');
      final pending = Completer<bool>();
      final operation = command(() => pending.future).execute();
      if (newBuild) {
        controller.markDownloadComplete(buildNumber: '12600');
        controller.markInstallPreparing(preparationProgress: .2);
      } else {
        controller.markSparkleDownloadStarted('full');
      }
      final before = controller.snapshot;
      pending.complete(false);
      expect(await operation, UpdateInstallResult.ignored);
      expect(controller.snapshot, before);
    }
  });
}
