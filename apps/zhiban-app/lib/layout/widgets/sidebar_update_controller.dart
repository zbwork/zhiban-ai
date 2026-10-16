import 'sidebar_update_state.dart';
import 'sidebar_update_event.dart';

class SidebarUpdateController {
  SidebarUpdateState? _stage;
  double? _progress;

  SidebarUpdateState? get stage => _stage;
  double? get progress => _progress;

  String? _pendingBuildNumber;

  String? get pendingBuildNumber => _pendingBuildNumber;

  (SidebarUpdateState?, String?, double?) get snapshot =>
      (_stage, _pendingBuildNumber, _progress);

  final Set<String?> _promptedBuilds = {};

  SidebarUpdateAction get primaryAction => switch (_stage) {
        SidebarUpdateState.readyToRestart => SidebarUpdateAction.restart,
        SidebarUpdateState.downloaded => SidebarUpdateAction.prepare,
        SidebarUpdateState.available ||
        SidebarUpdateState.failed =>
          SidebarUpdateAction.download,
        _ => SidebarUpdateAction.none,
      };

  bool claimRestartPrompt() {
    if (_stage != SidebarUpdateState.readyToRestart) return false;
    return _promptedBuilds.add(_pendingBuildNumber);
  }

  void accept(SidebarUpdateEvent event) {
    switch (event.type) {
      case SidebarUpdateEventType.downloadStarted:
        markDownloadStarted(event.buildNumber);
      case SidebarUpdateEventType.downloadComplete:
        markDownloadComplete(buildNumber: event.buildNumber);
      case SidebarUpdateEventType.downloadProgress:
        if (event.received != null && event.total != null) {
          markDownloadProgress(event.received!, event.total!);
        }
      case SidebarUpdateEventType.installPreparing:
        markInstallPreparing(preparationProgress: event.progress);
      case SidebarUpdateEventType.sparkleDownloadStarted:
        markSparkleDownloadStarted(event.packageType);
      case SidebarUpdateEventType.sparkleDownloadComplete:
        markSparkleDownloadComplete(event.packageType);
      case SidebarUpdateEventType.installReady:
        markInstallReady(buildNumber: event.buildNumber);
      case SidebarUpdateEventType.failed:
        markDownloadFailed();
    }
  }

  /// Lifecycle snapshots have no byte progress and must not reset live work.
  void restoreSnapshot({
    required bool pendingInstall,
    required bool downloading,
    bool cacheReady = false,
    String? buildNumber,
  }) {
    if (isBusy) return;
    if (pendingInstall) {
      restorePendingInstall(buildNumber);
    } else if (cacheReady) {
      markDownloadComplete(buildNumber: buildNumber);
    } else if (downloading) {
      markDownloadStarted(buildNumber);
    }
  }

  bool get hasUpdate => _stage != null;

  bool get isDownloaded =>
      _stage == SidebarUpdateState.downloaded ||
      _stage == SidebarUpdateState.preparing ||
      _stage == SidebarUpdateState.readyToRestart ||
      _stage == SidebarUpdateState.installing;

  bool get isBusy => _stage?.isBusy ?? false;

  bool get canStartDownload =>
      _stage == SidebarUpdateState.available ||
      _stage == SidebarUpdateState.failed;

  void applyServerUpdateAvailability(bool isAvailable,
      {String? latestBuildNumber}) {
    if (!isAvailable) {
      if (_stage == SidebarUpdateState.available) {
        _stage = null;
        _pendingBuildNumber = null;
        _progress = null;
      }
      return;
    }
    final latest = BigInt.tryParse(latestBuildNumber ?? '');
    final pending = BigInt.tryParse(_pendingBuildNumber ?? '');
    if (_stage == SidebarUpdateState.downloaded &&
        latest != null &&
        pending != null &&
        latest > pending) {
      _stage = SidebarUpdateState.available;
      _pendingBuildNumber = latestBuildNumber;
      _progress = null;
      return;
    }
    if (_stage == null) {
      _stage = SidebarUpdateState.available;
      _pendingBuildNumber = latestBuildNumber;
    } else if (_stage == SidebarUpdateState.available) {
      // available 状态下没有进行中的下载，跟着服务端最新号走没有副作用。
      _pendingBuildNumber = latestBuildNumber;
    } else if (_stage == SidebarUpdateState.failed) {
      // 下载失败后保持失败态，不被服务端轮询重置成 available，
      // 避免用户看到"下载中→新版本发布了→点击又失败"的循环。
      _pendingBuildNumber = latestBuildNumber;
    }
    // _stage 是 downloading/checking/installing 时不动 _pendingBuildNumber，
    // 避免覆盖掉正在下载的那个版本号，交给 markDownloadComplete 用真实完成的
    // buildNumber 校正。
  }

  void restorePendingInstall(String? buildNumber) {
    _stage = SidebarUpdateState.readyToRestart;
    _pendingBuildNumber = buildNumber;
    _progress = 1;
  }

  void markDownloadStarted(String? buildNumber) {
    _stage = SidebarUpdateState.downloading;
    _pendingBuildNumber = buildNumber;
    _progress = null;
  }

  void markDownloadProgress(int receivedBytes, int totalBytes) {
    if (_stage != SidebarUpdateState.downloading &&
        _stage != SidebarUpdateState.downloadingFull) {
      return;
    }
    if (totalBytes <= 0) {
      _progress = null;
      return;
    }
    _progress = (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  }

  void markSparkleDownloadStarted(String? packageType) {
    if (packageType != 'full') return;
    _stage = SidebarUpdateState.downloadingFull;
    _progress = null;
  }

  void markSparkleDownloadComplete(String? packageType) {
    if (packageType != 'full' || _stage != SidebarUpdateState.downloadingFull) {
      return;
    }
    _stage = SidebarUpdateState.preparing;
    _progress = null;
  }

  /// [buildNumber] 是原生 `downloadComplete` 事件里真实完成下载的版本号，用它
  /// 校正 `_pendingBuildNumber`——不传（或传空）时保留原值，避免把已经开始
  /// 下载、真正完成的版本号搞丢。
  void markDownloadComplete({String? buildNumber}) {
    _stage = SidebarUpdateState.downloaded;
    if (buildNumber != null && buildNumber.isNotEmpty) {
      _pendingBuildNumber = buildNumber;
    }
    _progress = 1;
  }

  void markInstallPreparing({double? preparationProgress}) {
    _stage = SidebarUpdateState.preparing;
    if (preparationProgress == null) {
      _progress = null;
    } else {
      _progress = preparationProgress.clamp(0, 1).toDouble();
    }
  }

  void markInstallReady({String? buildNumber}) {
    _stage = SidebarUpdateState.readyToRestart;
    if (buildNumber != null && buildNumber.isNotEmpty) {
      _pendingBuildNumber = buildNumber;
    }
    _progress = 1;
  }

  void markDownloadFailed() {
    if (_stage == SidebarUpdateState.installing ||
        _stage == SidebarUpdateState.readyToRestart) {
      return;
    }
    if (_stage == SidebarUpdateState.preparing) {
      _stage = SidebarUpdateState.downloaded;
      _progress = 1;
      return;
    }
    // 下载失败后直接隐藏侧栏提示，不显示"新版本发布了"也不显示失败态，
    // 避免用户反复点击反复失败。设置页主动检查更新仍可看到结果。
    _stage = null;
    _pendingBuildNumber = null;
    _progress = null;
  }

  void markChecking(bool value) {
    if (value) {
      _stage = isDownloaded
          ? SidebarUpdateState.preparing
          : SidebarUpdateState.checking;
      // Download progress is not installation progress. Do not display the
      // completed download's 100% while Sparkle is installing the update.
      if (_stage == SidebarUpdateState.preparing) _progress = null;
    } else if (_stage == SidebarUpdateState.preparing) {
      _stage = SidebarUpdateState.downloaded;
      _progress = 1;
    } else if (_stage == SidebarUpdateState.checking) {
      _stage = SidebarUpdateState.available;
    }
    // A completion event during the awaited check has already set a newer state.
  }

  void markRestarting() {
    _stage = SidebarUpdateState.installing;
    _progress = null;
  }
}
