import 'package:zhiban_client/services/desktop_update_service.dart';

extension DesktopUpdateCheckMessage on DesktopUpdateCheckResult {
  String get message => switch (this) {
        DesktopUpdateCheckResult.unavailable => '社区版暂未启用应用内更新',
        DesktopUpdateCheckResult.upToDate => '已是最新版本',
        DesktopUpdateCheckResult.downloaded => '更新已下载，请在左下角点击安装',
        DesktopUpdateCheckResult.readyToRestart => '安装已就绪，请在左下角点击重启应用',
        DesktopUpdateCheckResult.installing => '更新正在处理中，请查看左下角进度',
        DesktopUpdateCheckResult.failed => '检查或下载更新失败，请稍后重试',
      };
}

/// Presentation of the existing update events, independent of a long download
/// Future. Revisions prevent an older snapshot/result from erasing live progress.
class DesktopUpdateCheckFeedback {
  String? label;
  bool busy = false;
  int revision = 0;

  int _set(String label, {bool busy = false}) {
    this.label = label;
    this.busy = busy;
    return ++revision;
  }

  int begin() => _set('检查中', busy: true);

  void restore(DesktopUpdateState state, {required int ifUnchanged}) {
    if (revision != ifUnchanged) return;
    if (state.cacheReady) {
      _set('已下载');
    } else if (state.pendingInstall) {
      _set('安装已就绪');
    } else if (state.nativeSessionActive) {
      _set('更新处理中', busy: true);
    } else if (state.downloading) {
      _set('下载中', busy: true);
    } else if (state.checking) {
      _set('检查中', busy: true);
    }
  }

  void complete(DesktopUpdateCheckResult result, {required int ifUnchanged}) {
    if (revision != ifUnchanged) return;
    _set(
      switch (result) {
        DesktopUpdateCheckResult.unavailable => '社区版暂未启用应用内更新',
        DesktopUpdateCheckResult.upToDate => '已是最新版本',
        DesktopUpdateCheckResult.downloaded => '已下载',
        DesktopUpdateCheckResult.readyToRestart => '安装已就绪',
        DesktopUpdateCheckResult.installing => '更新处理中',
        DesktopUpdateCheckResult.failed => '检查或下载失败',
      },
      busy: result == DesktopUpdateCheckResult.installing
    );
  }

  void accept(Map<String, dynamic> event) {
    switch (event['event']) {
      case 'downloadStarted':
      case 'sparkleDownloadStarted':
        _set('下载中', busy: true);
      case 'downloadProgress':
        final received = event['receivedBytes'];
        final total = event['totalBytes'];
        final percentage = received is num && total is num && total > 0
            ? ' ${(received * 100 / total).clamp(0, 100).round()}%'
            : '';
        _set('下载中$percentage', busy: true);
      case 'downloadComplete':
        _set('已下载');
      case 'sparkleDownloadComplete':
      case 'installPreparing':
        _set('准备安装中', busy: true);
      case 'installReady':
        _set('安装已就绪');
      case 'installerLaunched':
        _set('安装程序已启动');
      case 'notFound':
        _set('已是最新版本');
      case 'failed':
        _set('检查或下载失败');
      case 'cancelled':
        _set('更新已取消');
    }
  }
}
