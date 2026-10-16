import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/services/app_update_service.dart';

enum AndroidDownloadStatus { idle, pending, running, waiting, ready, failed }

class AndroidUpdateDownload {
  const AndroidUpdateDownload({
    this.status = AndroidDownloadStatus.idle,
    this.downloadId,
    this.info,
    this.receivedBytes = 0,
    this.totalBytes = -1,
    this.message = '',
  });

  factory AndroidUpdateDownload.fromMap(Map<Object?, Object?> map) {
    final raw = map['update'];
    final update = raw is Map ? raw : const {};
    return AndroidUpdateDownload(
      status: AndroidDownloadStatus.values.firstWhere(
        (status) => status.name == map['status'],
        orElse: () => AndroidDownloadStatus.failed,
      ),
      downloadId: (map['downloadId'] as num?)?.toInt(),
      info: update.isEmpty
          ? null
          : AppUpdateInfo(
              currentVersion: '',
              currentBuildNumber: '',
              latestVersion: update['latestVersion'] as String? ?? '',
              latestBuildNumber: update['latestBuildNumber'] as String? ?? '',
              downloadUrl: update['downloadUrl'] as String? ?? '',
              title: update['title'] as String? ?? '',
              releaseNotes: update['releaseNotes'] as String? ?? '',
              isForced: update['isForced'] == true,
              isUpdateAvailable: true,
            ),
      receivedBytes: (map['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? -1,
      message: map['message'] as String? ?? '',
    );
  }

  final AndroidDownloadStatus status;
  final int? downloadId;
  final AppUpdateInfo? info;
  final int receivedBytes;
  final int totalBytes;
  final String message;

  bool get hasTask => downloadId != null && info != null;
  bool get isActive => const {
        AndroidDownloadStatus.pending,
        AndroidDownloadStatus.running,
        AndroidDownloadStatus.waiting,
      }.contains(status);
  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

class AndroidUpdateClient {
  const AndroidUpdateClient();

  static const _channel = MethodChannel('cn.qkfintech.zhiban/android_update');

  Future<AndroidUpdateDownload> _snapshot(String method,
      [Map<String, Object?>? arguments]) async {
    final value = await _channel
        .invokeMethod<Map<Object?, Object?>>(method, arguments)
        .timeout(const Duration(seconds: 10));
    if (value == null) {
      throw PlatformException(code: 'missing_state', message: '暂时无法读取下载进度');
    }
    return AndroidUpdateDownload.fromMap(value);
  }

  Future<AndroidUpdateDownload> query() => _snapshot('query');

  Future<AndroidUpdateDownload> start(AppUpdateInfo info) =>
      _snapshot('start', {
        'update': {
          'latestVersion': info.latestVersion,
          'latestBuildNumber': info.latestBuildNumber,
          'downloadUrl': info.downloadUrl,
          'title': info.title,
          'releaseNotes': info.releaseNotes,
          'isForced': info.isForced,
        },
      });

  Future<AndroidUpdateDownload> retry(int id) =>
      _snapshot('retry', {'downloadId': id});

  Future<String> install(int id) async =>
      await _channel.invokeMethod<String>('install', {'downloadId': id}) ??
      'unavailable';
}

class AndroidUpdateState {
  const AndroidUpdateState({
    this.download = const AndroidUpdateDownload(),
    this.busy = false,
    this.stalled = false,
    this.notice,
  });

  final AndroidUpdateDownload download;
  final bool busy;
  final bool stalled;
  final String? notice;

  bool get canWait => download.isActive;
  String get label => switch (download.status) {
        AndroidDownloadStatus.ready => '下载完成，点击安装',
        AndroidDownloadStatus.failed => '更新下载已停止，点击重试',
        AndroidDownloadStatus.waiting => '更新正在等待网络',
        _ when stalled => '更新暂时没有新进度',
        _ => download.progress == null
            ? '更新下载中'
            : '更新下载中 ${(download.progress! * 100).toStringAsFixed(0)}%',
      };
}

final androidUpdateClientProvider =
    Provider<AndroidUpdateClient>((ref) => const AndroidUpdateClient());
final androidUpdateClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);
final androidUpdateProvider =
    NotifierProvider<AndroidUpdateController, AndroidUpdateState>(
        AndroidUpdateController.new);

/// The native download ID is authoritative. UI disposal never cancels a download.
class AndroidUpdateController extends Notifier<AndroidUpdateState> {
  late AndroidUpdateClient _client;
  late DateTime Function() _now;
  Timer? _poll;
  DateTime? _lastProgressAt;
  bool _querying = false;
  bool _disposed = false;
  bool _pollingEnabled = true;
  int _revision = 0;

  @override
  AndroidUpdateState build() {
    _client = ref.read(androidUpdateClientProvider);
    _now = ref.read(androidUpdateClockProvider);
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
    });
    return const AndroidUpdateState();
  }

  void _accept(AndroidUpdateDownload download) {
    if (_disposed) return;
    if (download.downloadId != state.download.downloadId ||
        download.receivedBytes > state.download.receivedBytes) {
      _lastProgressAt = _now();
    }
    _lastProgressAt ??= _now();
    state = AndroidUpdateState(
      download: download,
      busy: state.busy,
      stalled: download.isActive &&
          _now().difference(_lastProgressAt!) >= const Duration(seconds: 30),
    );
    _updatePolling();
  }

  void _updatePolling() {
    if (!_pollingEnabled || !state.download.isActive) {
      _poll?.cancel();
      _poll = null;
    } else {
      _poll ??= Timer.periodic(
          const Duration(seconds: 2), (_) => unawaited(refresh()));
    }
  }

  void setForeground(bool foreground) {
    _pollingEnabled = foreground;
    _updatePolling();
    if (foreground) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed || _querying || state.busy) return;
    _querying = true;
    final revision = _revision;
    try {
      final download = await _client.query();
      if (revision == _revision) _accept(download);
    } catch (_) {
      if (!_disposed && revision == _revision) {
        state = AndroidUpdateState(
          download: state.download,
          stalled: state.download.isActive,
          notice: '暂时无法读取进度，下载任务仍保留',
        );
      }
    } finally {
      _querying = false;
    }
  }

  Future<void> continueWaiting() async {
    _lastProgressAt = _now();
    await refresh();
  }

  Future<void> start(AppUpdateInfo info) => _run(() async {
        // Native start also deduplicates across process restarts.
        _accept(await _client.start(info));
      });

  Future<void> retry() async {
    final id = state.download.downloadId;
    if (state.download.status != AndroidDownloadStatus.failed || id == null) {
      await continueWaiting();
      return;
    }
    await _run(() async => _accept(await _client.retry(id)));
  }

  Future<void> install() async {
    final id = state.download.downloadId;
    if (state.download.status != AndroidDownloadStatus.ready || id == null) {
      return;
    }
    await _run(() async {
      final String result;
      try {
        result = await _client.install(id);
      } on PlatformException catch (error) {
        if (const {'invalid_package', 'download_incomplete', 'missing_task'}
            .contains(error.code)) {
          // Native validation may have made this package retryable. Permission
          // or installer-launch errors keep the existing local APK ready.
          _accept(await _client.query());
        }
        rethrow;
      }
      if (_disposed) return;
      state = AndroidUpdateState(
        download: state.download,
        busy: true,
        notice: switch (result) {
          'permissionRequired' => '请在系统设置允许安装应用，返回后点击“立即安装”继续',
          'launched' => '请在系统安装器中完成安装，取消后仍可再次安装',
          _ => '无法打开安装器，请稍后重试',
        },
      );
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed || state.busy) return;
    _revision++;
    state = AndroidUpdateState(download: state.download, busy: true);
    try {
      await action();
    } catch (error) {
      if (!_disposed) {
        state = AndroidUpdateState(
          download: state.download,
          busy: true,
          notice: error is PlatformException
              ? error.message ?? '更新操作失败，请稍后重试'
              : '暂时无法操作更新任务，请稍后重试',
        );
      }
    } finally {
      if (!_disposed) {
        state = AndroidUpdateState(
          download: state.download,
          stalled: state.stalled,
          notice: state.notice,
        );
        _updatePolling();
      }
    }
  }
}
