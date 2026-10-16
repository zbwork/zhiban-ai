import 'dart:async';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';

/// F09 P2 媒体消息体验 (2026-06) — 文件下载进度 + 防重复 + reveal 控制器.
///
/// 见 docs/contracts/agent-bus-client-contract.md §「媒体消息体验 / 文件下载进度」.
///
/// 设计:
///   - **per-app 单实例** (Riverpod provider 注入), 维护 `Map<key, ChatMediaDownloadTask>`。
///   - **key = mediaUrl** (chat_media_ref 端点 URL 是稳定唯一; refUuid 同源)。
///   - 重复调 `start(url=X)` 时若 X 已在 `downloading` 态 → no-op + toast「该文件已在下载中」,
///     **不**重新发起 download (防同 url 并发 → 写入下载目录后还可能踩 unique 重命名)。
///   - 进度/状态变更 `notifyListeners()`,UI 层 (toast / 浮层) 监听并刷新。
///   - 完成态/失败态保留 30s 以便 UI toast 展示结束态, 然后自动 GC (避免无限堆积)。
///   - **不**写进 IM 消息权威模型 (`ImMessage` 不动): 这是本机 UI transient state。
///   - **不**做后台队列 / 断点续传 / 大文件分片。
///   - 下载失败 → toast + `error: e` 终态;调用方可再点 `start` 重试 (失败态不会阻塞新启动)。
enum ChatMediaDownloadStatus { idle, downloading, completed, failed, cancelled }

class ChatMediaDownloadTask {
  ChatMediaDownloadTask({
    required this.url,
    required this.name
  });
  final String url;
  final String name;

  ChatMediaDownloadStatus status = ChatMediaDownloadStatus.idle;
  int received = 0;
  int total = 0;
  String? error;
  File? file;
  CancelToken? cancelToken;

  /// 0..1, total<=0 时返回 `null` (indeterminate)。
  double? get fraction {
    if (total <= 0) return null;
    final f = received / total;
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }

  /// 4-decimal "42%" 样 UI 文案。`null` total → 「下载中…」。
  String get progressLabel {
    if (status == ChatMediaDownloadStatus.completed) return '已完成';
    if (status == ChatMediaDownloadStatus.failed) return '下载失败';
    if (status == ChatMediaDownloadStatus.cancelled) return '已取消';
    final f = fraction;
    if (f == null) return '下载中…';
    return '下载中 ${(f * 100).round()}%';
  }

  bool get isActive => status == ChatMediaDownloadStatus.downloading;
}

class ChatMediaDownloadController extends ChangeNotifier {
  ChatMediaDownloadController({this.downloadFn = downloadChatMediaToDownloads});

  /// 注入式 download fn (默认走 `downloadChatMediaToDownloads`);测试可换 fake。
  final Future<File> Function({
    required String url,
    required String name,
    bool reveal,
    bool isImage,
    void Function(int received, int total)? onReceiveProgress,
    CancelToken? cancelToken,
  }) downloadFn;

  final Map<String, ChatMediaDownloadTask> _tasks = {};
  final Map<String, Timer> _gcTimers = {};

  /// **CR-2026-06 dispose race**: dispose 后 `start` 的尾巴 (progress / complete / catch /
  /// finally) 仍可能跑;一律走 `_safeNotify` / 守 `_disposed`, 不能 notifyListeners /
  /// 不能新建 timer / 不能再 toast。`dispose` 本身幂等 (`super.dispose()` 也支持多次?
  /// 不支持; 这里加自旗保证调用方多次 dispose 不抛)。
  bool _disposed = false;
  bool get isDisposed => _disposed;

  Map<String, ChatMediaDownloadTask> get tasksSnapshot => Map.unmodifiable(_tasks);

  ChatMediaDownloadTask? taskOf(String url) => _tasks[url];

  bool isActive(String url) => _tasks[url]?.isActive ?? false;

  /// disposed 后的 no-op notifyListeners (避免 "A ChangeNotifier was used after being disposed")。
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 触发一次下载。
  /// - 同 url 已在 `downloading` → 返回 false + toast「该文件已在下载中」, **不**重新发起;
  /// - 否则建/复用 task,标 `downloading`,异步跑下载;
  /// - 完成/失败后保留 30s 让 UI 展示 toast,再 GC。
  /// disposed 后调用 → 直接返回 false, 不动 task map / 不 toast / 不 download。
  Future<bool> start({
    required String url,
    required String name,
    bool reveal = true,
    bool isImage = false,
    bool toast = true,
  }) async {
    if (_disposed) return false;
    if (url.trim().isEmpty) return false;
    final existing = _tasks[url];
    if (existing != null && existing.isActive) {
      if (toast) BotToast.showText(text: '该文件已在下载中');
      return false;
    }
    // 取消既有 GC (重试时复用 task slot)。
    _gcTimers.remove(url)?.cancel();
    final task = ChatMediaDownloadTask(url: url, name: name)
      ..status = ChatMediaDownloadStatus.downloading
      ..received = 0
      ..total = 0
      ..error = null
      ..file = null
      ..cancelToken = CancelToken();
    _tasks[url] = task;
    _safeNotify();
    final dismissLoading = toast ? BotToast.showLoading() : null;
    try {
      final file = await downloadFn(
        url: url,
        name: name,
        reveal: reveal,
        isImage: isImage,
        cancelToken: task.cancelToken,
        onReceiveProgress: (recv, tot) {
          // disposed 后 progress 回调被丢弃, 不写 task / 不 notify。
          if (_disposed) return;
          task.received = recv;
          task.total = tot;
          _safeNotify();
        },
      );
      dismissLoading?.call();
      if (_disposed) return false;
      task.file = file;
      task.status = ChatMediaDownloadStatus.completed;
      _safeNotify();
      if (toast) {
        if (PlatformUtils.isMobile) {
          if (isImage) BotToast.showText(text: '已保存到相册');
        } else {
          BotToast.showText(
              text: '已保存: ${file.path.split(Platform.pathSeparator).last}');
        }
      }
    } on DioException catch (e) {
      dismissLoading?.call();
      if (_disposed) return false;
      if (e.type == DioExceptionType.cancel) {
        task.status = ChatMediaDownloadStatus.cancelled;
        if (toast) BotToast.showText(text: '已取消');
      } else {
        task.status = ChatMediaDownloadStatus.failed;
        task.error = e.message ?? e.toString();
        if (toast) BotToast.showText(text: '下载失败,请检查网络');
      }
      _safeNotify();
    } catch (e) {
      dismissLoading?.call();
      if (_disposed) return false;
      task.status = ChatMediaDownloadStatus.failed;
      task.error = e.toString();
      _safeNotify();
      if (toast) BotToast.showText(text: '下载失败,请检查网络');
    } finally {
      // 已 dispose → 既不需要 GC 也不应该再建 timer。
      if (!_disposed) _scheduleGc(url);
    }
    return task.status == ChatMediaDownloadStatus.completed;
  }

  /// 取消指定 url 当前下载 (仅 downloading 态有效)。disposed 后 no-op。
  void cancel(String url) {
    if (_disposed) return;
    final t = _tasks[url];
    if (t == null || !t.isActive) return;
    try {
      t.cancelToken?.cancel('user cancelled');
    } catch (_) {}
  }

  /// 已完成 / 失败 / 取消的任务保留 30s,然后从 map 移除。disposed 后直接返回, 不建 timer;
  /// timer callback 触发时再次守 `_disposed`,避免 30s 内 dispose 后还跑回调。
  void _scheduleGc(String url) {
    if (_disposed) return;
    _gcTimers.remove(url)?.cancel();
    _gcTimers[url] = Timer(const Duration(seconds: 30), () {
      if (_disposed) return;
      _tasks.remove(url);
      _gcTimers.remove(url);
      _safeNotify();
    });
  }

  @override
  void dispose() {
    if (_disposed) return; // 幂等: 多次 dispose 不抛, 不调 super 第二次。
    _disposed = true;
    for (final t in _gcTimers.values) {
      try {
        t.cancel();
      } catch (_) {}
    }
    _gcTimers.clear();
    for (final t in _tasks.values) {
      try {
        t.cancelToken?.cancel('controller disposed');
      } catch (_) {}
    }
    _tasks.clear();
    super.dispose();
  }
}

/// per-app 单实例; 桌面/移动一份。pane 用 `ref.read(chatMediaDownloadControllerProvider)`
/// 触发 download; UI 用 `ref.watch(...)` 拿到 controller 实例后挂 `AnimatedBuilder` /
/// `ListenableBuilder` 监听变化 (与 `rtcCallControllerProvider` 同模式)。
final chatMediaDownloadControllerProvider =
    Provider<ChatMediaDownloadController>((ref) {
  final ctl = ChatMediaDownloadController();
  ref.onDispose(ctl.dispose);
  return ctl;
});
