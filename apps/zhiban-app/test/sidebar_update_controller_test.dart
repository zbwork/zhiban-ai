import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/layout/widgets/sidebar_update_controller.dart';
import 'package:nexwork/layout/widgets/sidebar_update_indicator.dart';

void main() {
  test('shows full package download before returning to preparation', () {
    final controller = SidebarUpdateController()
      ..markInstallPreparing()
      ..markSparkleDownloadStarted('full');

    expect(controller.stage, SidebarUpdateState.downloadingFull);
    expect(controller.progress, isNull);

    controller.markDownloadProgress(25, 100);
    expect(controller.progress, 0.25);

    controller.markSparkleDownloadComplete('full');
    expect(controller.stage, SidebarUpdateState.preparing);
  });

  test('resume preserves known download progress and target', () {
    final controller = SidebarUpdateController()
      ..markDownloadStarted('12300')
      ..markDownloadProgress(71, 100);
    final before = controller.snapshot;
    controller.restoreSnapshot(pendingInstall: false, downloading: true);
    expect(controller.snapshot, before);
    controller.markDownloadProgress(72, 100);
    expect(controller.progress, .72);
    expect(controller.pendingBuildNumber, '12300');
  });

  test('cached ready snapshot cannot replace an active download', () {
    final controller = SidebarUpdateController()
      ..markDownloadStarted('12300')
      ..markDownloadProgress(71, 100);
    final before = controller.snapshot;
    controller.restoreSnapshot(
        pendingInstall: true, downloading: false, buildNumber: '12200');
    expect(controller.snapshot, before);
  });

  test('resume cannot revert restart handoff to ready', () {
    final controller = SidebarUpdateController()
      ..restorePendingInstall('12300')
      ..markChecking(true);
    controller.restoreSnapshot(
        pendingInstall: true, downloading: false, buildNumber: '12300');
    expect(controller.stage, SidebarUpdateState.preparing);
    expect(controller.progress, isNull);
  });

  test('initial restore works and identical data has an equal snapshot', () {
    final controller = SidebarUpdateController();
    controller.restoreSnapshot(
        pendingInstall: true, downloading: false, buildNumber: '12300');
    expect(controller.stage, SidebarUpdateState.readyToRestart);
    final before = controller.snapshot;
    controller.restoreSnapshot(
        pendingInstall: true, downloading: false, buildNumber: '12300');
    expect(controller.snapshot, before);
  });

  test('download, preparation and restart readiness are distinct states', () {
    final controller = SidebarUpdateController()
      ..markDownloadComplete(buildNumber: '12400');
    expect(controller.stage, SidebarUpdateState.downloaded);

    controller.markInstallPreparing(preparationProgress: .42);
    expect(controller.stage, SidebarUpdateState.preparing);
    expect(controller.progress, .42);

    controller.markInstallReady(buildNumber: '12400');
    expect(controller.stage, SidebarUpdateState.readyToRestart);
    expect(controller.progress, 1);

    controller.markRestarting();
    expect(controller.stage, SidebarUpdateState.installing);
    expect(controller.stage?.title, '正在安装更新…');
    expect(controller.stage?.description, '完成后将自动重启');
    expect(controller.progress, isNull);
  });

  test('an explicit new download still resets progress', () {
    final controller = SidebarUpdateController()
      ..markDownloadStarted('12300')
      ..markDownloadProgress(71, 100)
      ..markDownloadStarted('12400');
    expect(controller.progress, isNull);
    expect(controller.pendingBuildNumber, '12400');
  });
}
