import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'app_update_service.dart';
import 'desktop_update_cache.dart';

enum DesktopUpdateCheckResult {
  upToDate,
  downloaded,
  readyToRestart,
  installing,
  failed,
}

class DesktopUpdateState {
  const DesktopUpdateState({
    required this.pendingInstall,
    required this.pendingBuildNumber,
    required this.canCheckForUpdates,
    this.downloading = false,
    this.checking = false,
    this.cacheReady = false,
    this.nativeSessionActive = false,
  });

  const DesktopUpdateState.unavailable()
      : pendingInstall = false,
        pendingBuildNumber = '',
        canCheckForUpdates = false,
        downloading = false,
        checking = false,
        cacheReady = false,
        nativeSessionActive = false;

  factory DesktopUpdateState.fromMap(Map<Object?, Object?> map) {
    return DesktopUpdateState(
      pendingInstall: map['pendingInstall'] == true,
      pendingBuildNumber: (map['pendingBuildNumber'] as String?) ?? '',
      canCheckForUpdates: map['canCheckForUpdates'] == true,
      nativeSessionActive: map['sessionInProgress'] == true,
    );
  }

  final bool pendingInstall;
  final String pendingBuildNumber;
  final bool canCheckForUpdates;
  final bool downloading;
  final bool checking;
  final bool cacheReady;
  final bool nativeSessionActive;
}

/// 桌面端应用更新原生桥（macOS Sparkle / Windows WinSparkle），共用
/// `cn.qkfintech.zhiban/update` 通道。
class DesktopUpdateCoordinator {
  DesktopUpdateCoordinator(
      {DesktopUpdateCache? cache,
      Future<AppUpdateInfo?> Function()? fetchInfo}) {
    if (cache != null) _cache = cache;
    if (fetchInfo != null) _fetchInfo = fetchInfo;
  }

  Future<DesktopUpdateCheckResult>? _checkOperation;
  Future<bool>? _installOperation;
  int _nativeRevision = 0;

  var _cache = DesktopUpdateCache.local();
  Future<AppUpdateInfo?> Function() _fetchInfo =
      () => AppUpdateService().fetchUpdateInfo();
  Future<CachedDesktopUpdate?>? _preparation;
  int _lastLoggedProgressBucket = -1;
  String? _lastLoggedState;

  void _log(String message) {
    debugPrint('[Update] source=flutter $message');
  }

  @visibleForTesting
  Future<void> configureForTesting({
    required DesktopUpdateCache cache,
    required Future<AppUpdateInfo?> Function() fetchInfo,
  }) async {
    await _cache.close();
    _cache = cache;
    _fetchInfo = fetchInfo;
    _preparation = null;
    _checkOperation = null;
    _installOperation = null;
    _nativeRevision = 0;
    _lastLoggedProgressBucket = -1;
    _lastLoggedState = null;
  }

  final MethodChannel _channel = MethodChannel('cn.qkfintech.zhiban/update');

  final StreamController<Map<String, dynamic>> _updateEventsController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// macOS Sparkle 下载进度事件流（由 Swift 侧通过 invokeMethod 推送）。
  Stream<Map<String, dynamic>> get updateEvents =>
      _updateEventsController.stream;

  /// 桌面侧栏挂载时调用一次，注册 Swift→Dart 事件接收。
  void registerUpdateEventHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'updateEvent') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final revision = ++_nativeRevision;
        _log('native event: $args');
        if (const {'failed', 'cancelled', 'notFound', 'installerLaunched'}
            .contains(args['event'])) {
          CachedDesktopUpdate? cached;
          try {
            cached = await _restoreCache();
          } catch (_) {
            // Publish the original failure even when storage cannot be read.
          }
          if (revision != _nativeRevision) return;
          if (cached != null) {
            _notifyReady(cached);
            if (args['event'] == 'failed') {
              _log('native install failed; cached package retained');
            }
            return;
          }
        }
        _updateEventsController.add(args);
      }
    });
  }

  Future<CachedDesktopUpdate?> _restoreCache() async {
    try {
      return await _cache.restore();
    } catch (error) {
      _log('cache restore failed; error_type=${error.runtimeType}');
      rethrow;
    }
  }

  void _notifyReady(CachedDesktopUpdate cached) {
    _log('cache download complete; cache_package=${cached.packageType} '
        'version=${cached.version} build=${cached.buildNumber} '
        'size=${cached.size}');
    _updateEventsController.add({
      'event': 'downloadComplete',
      'buildNumber': cached.buildNumber,
      'version': cached.version
    });
  }

  Future<CachedDesktopUpdate?> _ensureCached(String? feedUrl) =>
      _preparation ??=
          _prepareCache(feedUrl).whenComplete(() => _preparation = null);

  Future<CachedDesktopUpdate?> _prepareCache(String? feedUrl) async {
    _log('cache preparation started; cache_package=selecting');
    final cached = await _restoreCache();
    if (cached != null) {
      _log('cache restored; cache_package=${cached.packageType} '
          'version=${cached.version} build=${cached.buildNumber} '
          'size=${cached.size}');
    }
    AppUpdateInfo? info;
    try {
      info = await _fetchInfo();
    } catch (error) {
      if (cached == null) rethrow;
      _log('latest update query failed; cached_build=${cached.buildNumber} '
          'error_type=${error.runtimeType}');
      _notifyReady(cached);
      return cached;
    }
    if (info == null) {
      if (cached != null) {
        _notifyReady(cached);
        return cached;
      }
      throw StateError('暂时无法获取更新信息');
    }
    _log('server update; available=${info.isUpdateAvailable} '
        'current_version=${info.currentVersion} '
        'current_build=${info.currentBuildNumber} '
        'latest_version=${info.latestVersion} '
        'latest_build=${info.latestBuildNumber}');
    if (!info.isUpdateAvailable) {
      // 服务端说没有新版本时,缓存只有正好是那一版才值得留:否则它是已被取代或
      // 下线的包,留着会让卡片一直显示"可安装"却装不上(2026-09-16)。
      if (cached != null && cached.buildNumber == info.latestBuildNumber) {
        _notifyReady(cached);
        return cached;
      }
      return null;
    }
    final updateInfo = info;
    _lastLoggedProgressBucket = -1;
    _log('cache download started; cache_package=selecting '
        'current_version=${updateInfo.currentVersion} '
        'current_build=${updateInfo.currentBuildNumber} '
        'latest_version=${updateInfo.latestVersion} '
        'latest_build=${updateInfo.latestBuildNumber}');
    _updateEventsController.add({
      'event': 'downloadStarted',
      'buildNumber': updateInfo.latestBuildNumber,
    });
    try {
      final downloaded = await _cache.download(
          updateInfo, Uri.parse(feedUrl ?? AppUpdateService.appcastUrl()),
          onProgress: (received, total, {required packageType}) {
        _updateEventsController.add({
          'event': 'downloadProgress',
          'buildNumber': updateInfo.latestBuildNumber,
          'receivedBytes': received,
          'totalBytes': total,
        });
        if (total > 0) {
          final bucket = (received * 10 ~/ total).clamp(0, 10);
          if (bucket != _lastLoggedProgressBucket || received >= total) {
            _lastLoggedProgressBucket = bucket;
            _log('cache download progress; cache_package=$packageType '
                'build=${updateInfo.latestBuildNumber} '
                'received=$received total=$total '
                'percent=${(received * 100 / total).toStringAsFixed(1)}');
          }
        }
      });
      _notifyReady(downloaded);
      return downloaded;
    } catch (error) {
      _log('cache download failed; cache_package=selected '
          'type=${error.runtimeType}');
      _updateEventsController
          .add({'event': 'failed', 'message': error.toString()});
      rethrow;
    }
  }

  /// The profile menu, settings page, and sidebar all share this background
  /// check. It never opens Sparkle's own check window.
  Future<bool> checkAndDownloadUpdate({String? feedUrl}) async =>
      await checkForUpdates(feedUrl: feedUrl) != DesktopUpdateCheckResult.failed;

  /// Returns the completed outcome, not merely whether a check was accepted.
  Future<DesktopUpdateCheckResult> checkForUpdates({String? feedUrl}) =>
      _checkOperation ??= _checkAndDownload(feedUrl: feedUrl)
          .whenComplete(() => _checkOperation = null);

  Future<DesktopUpdateCheckResult> _checkAndDownload({String? feedUrl}) async {
    if (!PlatformUtils.isDesktop) return DesktopUpdateCheckResult.failed;
    _log('manual check requested');
    try {
      final native = await _nativeState();
      if (native.pendingInstall || native.nativeSessionActive) {
        _log('manual check found pending install; '
            'build=${native.pendingBuildNumber}');
        return native.pendingInstall
            ? DesktopUpdateCheckResult.readyToRestart
            : DesktopUpdateCheckResult.installing;
      }
      final cached = await _ensureCached(feedUrl);
      if (cached == null) {
        _log('manual check completed; result=up_to_date');
        _updateEventsController.add({'event': 'notFound'});
        return DesktopUpdateCheckResult.upToDate;
      }
      _log('manual check completed; result=update_ready '
          'cache_package=${cached.packageType} version=${cached.version} '
          'build=${cached.buildNumber}');
      return DesktopUpdateCheckResult.downloaded;
    } catch (error) {
      _log('manual check failed; type=${error.runtimeType}');
      // Pages opened during a check also need a terminal event when its query
      // fails before any download events have been emitted.
      _updateEventsController.add({
        'event': 'failed',
        'message': '检查或下载更新失败，请稍后重试',
      });
      return DesktopUpdateCheckResult.failed;
    }
  }

  Future<bool> installUpdateInBackground({String? feedUrl}) =>
      _installOperation ??= _install(prepare: true, feedUrl: feedUrl)
          .whenComplete(() => _installOperation = null);

  Future<bool> _install({required bool prepare, String? feedUrl}) async {
    if (!PlatformUtils.isDesktop) return false;
    try {
      final native = await _nativeState();
      if (native.pendingInstall) {
        return await _channel.invokeMethod<bool>('installPendingUpdate') ??
            false;
      }
      if (native.nativeSessionActive) return true;
      if (prepare && await _ensureCached(feedUrl) == null) return false;
      return await _installCachedUpdate();
    } catch (error) {
      _log('install failed; type=${error.runtimeType}');
      return false;
    }
  }

  /// Installs the package that has already been durably cached. This path must
  /// not call [_ensureCached], because that method is allowed to download a
  /// newer server release and would turn an install click back into a download.
  Future<bool> _installCachedUpdate() async {
    final cached = await _restoreCache();
    if (cached == null) {
      _log('install requested but no cached update exists');
      return false;
    }
    _log('install cached update; build=${cached.buildNumber}');
    final feedUrl = (await _cache.installationFeed(cached)).toString();
    return await _channel.invokeMethod<bool>('installUpdateInBackground', {
          'feedUrl': feedUrl,
        }) ??
        false;
  }

  Future<bool> installPendingUpdate() => _installOperation ??=
      _install(prepare: false).whenComplete(() => _installOperation = null);

  Future<DesktopUpdateState> _nativeState() async {
    try {
      final value =
          await _channel.invokeMethod<Map<Object?, Object?>>('getUpdateState');
      return value == null
          ? const DesktopUpdateState.unavailable()
          : DesktopUpdateState.fromMap(value);
    } catch (_) {
      return const DesktopUpdateState.unavailable();
    }
  }

  Future<DesktopUpdateState> getUpdateState() async {
    if (!PlatformUtils.isDesktop) return const DesktopUpdateState.unavailable();
    final native = await _nativeState();
    if (native.pendingInstall || native.nativeSessionActive) {
      _logUpdateState(native, native, cacheState: 'not_checked');
      return native;
    }
    CachedDesktopUpdate? cached;
    try {
      cached = await _restoreCache();
    } catch (_) {
      _logUpdateState(native, native, cacheState: 'error');
      return native;
    }
    final state = cached == null
        ? DesktopUpdateState(
            pendingInstall: false,
            pendingBuildNumber: '',
            canCheckForUpdates:
                native.canCheckForUpdates && _preparation == null,
            downloading: _cache.isDownloading,
            checking: _preparation != null && !_cache.isDownloading,
          )
        : DesktopUpdateState(
            pendingInstall: true,
            pendingBuildNumber: cached.buildNumber,
            cacheReady: true,
            canCheckForUpdates: !_cache.isDownloading,
          );
    _logUpdateState(native, state,
        cacheState: cached == null ? 'unavailable' : 'ready', cached: cached);
    return state;
  }

  void _logUpdateState(DesktopUpdateState native, DesktopUpdateState state,
      {required String cacheState, CachedDesktopUpdate? cached}) {
    final message = 'state native_pending=${native.pendingInstall} '
        'cache_state=$cacheState cache_package=${cached?.packageType ?? 'none'} '
        'target_build=${state.pendingBuildNumber} '
        'delta_from_build=${cached?.deltaFromBuild ?? 'none'} '
        'ui_ready=${state.pendingInstall} checking=${state.checking} '
        'downloading=${state.downloading} '
        'can_check=${state.canCheckForUpdates}';
    if (_lastLoggedState != message) {
      _lastLoggedState = message;
      _log(message);
    }
  }

  Future<String?> updateFeedUrl() async {
    if (!PlatformUtils.isDesktop) {
      return null;
    }

    try {
      return await _channel.invokeMethod<String>('getUpdateFeedUrl');
    } catch (_) {
      return null;
    }
  }
}

/// Compatibility facade. All UI entry points share one coordinator.
class DesktopUpdateService {
  DesktopUpdateService._();
  static final _coordinator = DesktopUpdateCoordinator();
  static Stream<Map<String, dynamic>> get updateEvents =>
      _coordinator.updateEvents;
  static void registerUpdateEventHandler() =>
      _coordinator.registerUpdateEventHandler();
  static Future<bool> checkAndDownloadUpdate({String? feedUrl}) =>
      _coordinator.checkAndDownloadUpdate(feedUrl: feedUrl);
  static Future<DesktopUpdateCheckResult> checkForUpdates({String? feedUrl}) =>
      _coordinator.checkForUpdates(feedUrl: feedUrl);
  static Future<bool> installUpdateInBackground({String? feedUrl}) =>
      _coordinator.installUpdateInBackground(feedUrl: feedUrl);
  static Future<bool> installPendingUpdate() =>
      _coordinator.installPendingUpdate();
  static Future<DesktopUpdateState> getUpdateState() =>
      _coordinator.getUpdateState();
  static Future<String?> updateFeedUrl() => _coordinator.updateFeedUrl();
  @visibleForTesting
  static Future<void> configureForTesting(
          {required DesktopUpdateCache cache,
          required Future<AppUpdateInfo?> Function() fetchInfo}) =>
      _coordinator.configureForTesting(cache: cache, fetchInfo: fetchInfo);
}
