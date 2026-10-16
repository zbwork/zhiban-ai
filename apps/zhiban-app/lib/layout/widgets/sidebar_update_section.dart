import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:zhiban_client/services/desktop_update_service.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import 'sidebar_update_controller.dart';
import 'sidebar_update_event.dart';
import 'sidebar_update_install_command.dart';
import 'sidebar_update_indicator.dart';

class SidebarUpdateSection extends StatefulWidget {
  const SidebarUpdateSection({super.key, this.collapsed = false});

  final bool collapsed;

  @override
  State<SidebarUpdateSection> createState() => _SidebarUpdateSectionState();
}

class _SidebarUpdateSectionState extends State<SidebarUpdateSection>
    with WidgetsBindingObserver {
  final _update = SidebarUpdateController();
  bool _refreshingUpdateInfo = false;
  bool _restoringUpdateInfo = false;
  int _updateRevision = 0;
  StreamSubscription<Map<String, dynamic>>? _updateEventSub;
  bool _restartDialogVisible = false;
  late final _installCommand = SidebarUpdateInstallCommand(
    controller: _update,
    install: DesktopUpdateService.installPendingUpdate,
    onChanged: (change) {
      if (mounted) _updateState(change);
    },
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (PlatformUtils.isDesktop) {
      DesktopUpdateService.registerUpdateEventHandler();
      _updateEventSub =
          DesktopUpdateService.updateEvents.listen(_onUpdateEvent);
      unawaited(_restoreAndRefreshAppUpdateInfo());
    } else {
      unawaited(_restoreAndRefreshAppUpdateInfo());
    }
  }

  @override
  void dispose() {
    _updateEventSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_restoreAndRefreshAppUpdateInfo());
    }
  }

  void _updateState(VoidCallback update) {
    final before = _update.snapshot;
    update();
    if (_update.snapshot == before) return;
    _updateRevision++;
    setState(() {});
  }

  void _onUpdateEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final parsed = SidebarUpdateEvent.fromMap(event);
    if (parsed == null) return;
    _updateState(() => _update.accept(parsed));
    if (parsed.type == SidebarUpdateEventType.installReady) {
      unawaited(_promptRestart());
    }
  }

  Future<void> _restoreAndRefreshAppUpdateInfo() async {
    if (_restoringUpdateInfo) return;
    _restoringUpdateInfo = true;
    final revision = _updateRevision;
    try {
      final nativeState = await DesktopUpdateService.getUpdateState();
      if (!mounted) return;
      if (revision == _updateRevision) {
        _updateState(() => _update.restoreSnapshot(
              pendingInstall:
                  nativeState.pendingInstall && !nativeState.cacheReady,
              cacheReady: nativeState.cacheReady,
              downloading: nativeState.downloading,
              buildNumber: nativeState.pendingBuildNumber.isEmpty
                  ? null
                  : nativeState.pendingBuildNumber,
            ));
      }
      if (_update.stage == SidebarUpdateState.readyToRestart) {
        unawaited(_promptRestart());
      }
      await _refreshAppUpdateInfo();
    } finally {
      _restoringUpdateInfo = false;
    }
  }

  Future<void> _refreshAppUpdateInfo() async {
    if (_refreshingUpdateInfo) return;
    _refreshingUpdateInfo = true;
    try {
      final info = await AppUpdateService().fetchUpdateInfo();
      if (!mounted) return;
      if (info == null) return;
      _updateState(
        () => _update.applyServerUpdateAvailability(
          info.isUpdateAvailable,
          latestBuildNumber: info.latestBuildNumber,
        ),
      );
      // Keep macOS automatic downloading; Windows downloads on its explicit entrypoint.
      // 自动下载只在 available 时触发；failed 状态不自动重试，避免
      // "下载中→失败→又显示新版本发布了→点击又失败"的循环。
      if (PlatformUtils.isMacOS &&
          info.isUpdateAvailable &&
          _update.stage == SidebarUpdateState.available) {
        _updateState(() => _update.markDownloadStarted(info.latestBuildNumber));
        final launched = await DesktopUpdateService.checkAndDownloadUpdate(
          feedUrl: AppUpdateService.appcastUrl(),
        );
        if (!mounted || launched) return;

        final nativeState = await DesktopUpdateService.getUpdateState();
        if (!mounted) return;
        _updateState(
          nativeState.pendingInstall
              ? () =>
                  _update.restorePendingInstall(nativeState.pendingBuildNumber)
              : _update.markDownloadFailed,
        );
      }
    } finally {
      _refreshingUpdateInfo = false;
    }
  }

  Future<void> _checkForUpdatesFromSidebar() async {
    switch (_update.primaryAction) {
      case SidebarUpdateAction.none:
        return;
      case SidebarUpdateAction.prepare:
      case SidebarUpdateAction.restart:
        await _executeInstall();
        return;
      case SidebarUpdateAction.download:
        break;
    }
    // 下载路径：直接进入 downloading，失败后停在 failed，不回退 available。
    _updateState(() => _update.markDownloadStarted(_update.pendingBuildNumber));
    try {
      final launched = await DesktopUpdateService.checkAndDownloadUpdate(
        feedUrl: AppUpdateService.appcastUrl(),
      );
      if (!mounted) return;
      if (!launched) {
        _updateState(_update.markDownloadFailed);
        BotToast.showText(text: '下载失败，请稍后在设置页检查更新');
      }
    } catch (e) {
      if (!mounted) return;
      _updateState(_update.markDownloadFailed);
      BotToast.showText(text: '下载失败：$e');
    }
    unawaited(_refreshAppUpdateInfo());
  }

  Future<void> _promptRestart() async {
    if (!mounted || _restartDialogVisible || !_update.claimRestartPrompt()) {
      return;
    }
    _restartDialogVisible = true;
    try {
      final confirmed = await showUiConfirmDialog(
        context,
        title: '安装已就绪',
        description: '升级已准备就绪，是否立即重启应用完成升级？',
        cancelLabel: '稍后',
        confirmLabel: '确定',
      );
      if (!confirmed ||
          !mounted ||
          _update.primaryAction != SidebarUpdateAction.restart) {
        return;
      }
      await _executeInstall();
    } finally {
      _restartDialogVisible = false;
    }
  }

  Future<void> _executeInstall() async {
    final restarting = _update.primaryAction == SidebarUpdateAction.restart;
    final result = await _installCommand.execute();
    if (!mounted || result != UpdateInstallResult.failed) return;
    BotToast.showText(text: restarting ? '重启失败，请稍后重试' : '安装失败，请稍后重试');
  }

  @override
  Widget build(BuildContext context) {
    if (!_update.hasUpdate) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SidebarUpdateIndicator(
        collapsed: widget.collapsed,
        state: _update.stage!,
        progress: _update.progress,
        onTap: _update.isBusy ? null : _checkForUpdatesFromSidebar,
      ),
    );
  }
}
