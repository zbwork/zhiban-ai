import 'sidebar_update_controller.dart';
import 'sidebar_update_state.dart';

enum UpdateInstallResult { ignored, launched, failed }

/// One entry point for prepare/restart with an injectable native operation.
class SidebarUpdateInstallCommand {
  SidebarUpdateInstallCommand(
      {required this.controller,
      required this.install,
      required this.onChanged});

  final SidebarUpdateController controller;
  final Future<bool> Function() install;
  final void Function(void Function()) onChanged;
  bool _running = false;

  Future<UpdateInstallResult> execute() async {
    final action = controller.primaryAction;
    if (_running ||
        (action != SidebarUpdateAction.prepare &&
            action != SidebarUpdateAction.restart)) {
      return UpdateInstallResult.ignored;
    }
    _running = true;
    onChanged(action == SidebarUpdateAction.restart
        ? controller.markRestarting
        : () => controller.markChecking(true));
    final startedStage = controller.stage;
    final startedBuild = controller.pendingBuildNumber;
    try {
      if (await install()) return UpdateInstallResult.launched;
    } catch (_) {
      // A thrown transport failure has the same retry semantics as false.
    } finally {
      _running = false;
    }
    // Progress alone does not transfer ownership of failure recovery.
    if (controller.stage != startedStage ||
        controller.pendingBuildNumber != startedBuild) {
      return UpdateInstallResult.ignored;
    }
    onChanged(action == SidebarUpdateAction.restart
        ? () => controller.markInstallReady()
        : () => controller.markChecking(false));
    return UpdateInstallResult.failed;
  }
}
