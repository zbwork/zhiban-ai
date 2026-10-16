import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/providers/chat_media_download_controller.dart';

// F09 P2 媒体消息体验 (2026-06): 下载控制器 — 进度 / 防重复 / 完成 / 失败 / 取消.
// 见 docs/contracts/agent-bus-client-contract.md §「媒体消息体验 / 文件下载进度」.

void main() {
  group('ChatMediaDownloadController', () {
    test('start: 触发 downloadFn 并写 progress, 完成后 status=completed', () async {
      final calls = <Map<String, dynamic>>[];
      final completer = Completer<File>();
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          calls.add({'url': url, 'name': name});
          onReceiveProgress?.call(50, 100);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          onReceiveProgress?.call(100, 100);
          return completer.future;
        },
      );
      // 完成 fake file
      final fakeFile = File('/tmp/fake-${DateTime.now().millisecondsSinceEpoch}');
      // ignore: discarded_futures
      ctl.start(url: 'u1', name: 'a.pdf', toast: false);
      // 给 future 一点时间推进, 让 progress 进 50%
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final t = ctl.taskOf('u1')!;
      expect(t.status, ChatMediaDownloadStatus.downloading);
      // 推进完成
      completer.complete(fakeFile);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.status, ChatMediaDownloadStatus.completed);
      expect(t.file, fakeFile);
      expect(calls.length, 1);
      ctl.dispose();
    });

    test('防重复: 同 url 已 downloading 时 start 返回 false, downloadFn 只调一次',
        () async {
      final calls = <String>[];
      final block = Completer<File>();
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          calls.add(url);
          return block.future;
        },
      );
      // ignore: discarded_futures
      ctl.start(url: 'u', name: 'a', toast: false);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final secondResult = await ctl.start(url: 'u', name: 'a', toast: false);
      expect(secondResult, isFalse);
      expect(calls, ['u']); // 只调用了一次
      block.complete(File('/tmp/x'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctl.dispose();
    });

    test('失败 → status=failed + error 写入 + toast 不抛 (catch 兜底)', () async {
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          throw StateError('network down');
        },
      );
      final ok = await ctl.start(url: 'u', name: 'a', toast: false);
      expect(ok, isFalse);
      final t = ctl.taskOf('u')!;
      expect(t.status, ChatMediaDownloadStatus.failed);
      expect(t.error, contains('network down'));
      ctl.dispose();
    });

    test('DioException.cancel → status=cancelled (不计为失败)', () async {
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
          );
        },
      );
      await ctl.start(url: 'u', name: 'a', toast: false);
      expect(ctl.taskOf('u')!.status, ChatMediaDownloadStatus.cancelled);
      ctl.dispose();
    });

    test('fraction: total>0 → received/total; total<=0 → null (indeterminate)',
        () {
      final t = ChatMediaDownloadTask(url: 'u', name: 'a')
        ..total = 100
        ..received = 42
        ..status = ChatMediaDownloadStatus.downloading;
      expect(t.fraction, 0.42);
      expect(t.progressLabel, '下载中 42%');
      t.total = 0;
      expect(t.fraction, isNull);
      expect(t.progressLabel, '下载中…');
      t.status = ChatMediaDownloadStatus.completed;
      expect(t.progressLabel, '已完成');
      t.status = ChatMediaDownloadStatus.failed;
      expect(t.progressLabel, '下载失败');
      t.status = ChatMediaDownloadStatus.cancelled;
      expect(t.progressLabel, '已取消');
    });

    test('完成态后 30s GC: cancel timer 在 dispose 时安全', () async {
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          return File('/tmp/x');
        },
      );
      await ctl.start(url: 'u', name: 'a', toast: false);
      expect(ctl.taskOf('u'), isNotNull); // 立即仍在 (待 GC)
      ctl.dispose(); // dispose 取消 GC timer, 测试不需要等 30s
    });
  });

  group('ChatMediaDownloadController dispose race (CR-2026-06)', () {
    test('start 一个未完成 fake download → dispose → 之后 progress/complete 不抛 disposed notifier',
        () async {
      final completer = Completer<File>();
      void Function(int, int)? capturedProgress;
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          capturedProgress = onReceiveProgress;
          return completer.future;
        },
      );
      // 启动一个未完成的下载。
      // ignore: discarded_futures
      ctl.start(url: 'u', name: 'a', toast: false);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // dispose, 此时 download future 仍未 resolve。
      ctl.dispose();
      expect(ctl.isDisposed, isTrue);
      // 之后再触发 fake progress: 不应抛 "ChangeNotifier used after disposed"。
      expect(() => capturedProgress?.call(50, 100), returnsNormally);
      // 完成 future, 让 start 走完 complete/finally 分支: 也不应抛。
      expect(() {
        completer.complete(File('/tmp/x'));
      }, returnsNormally);
      // 给 start 的 then/catch/finally 跑一轮。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // disposed 后 task map 已清空, 不应被「complete」重新写入。
      expect(ctl.taskOf('u'), isNull);
    });

    test('dispose 后 cancel/start 都 no-op, 不抛', () async {
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          return File('/tmp/x');
        },
      );
      ctl.dispose();
      expect(() => ctl.cancel('u'), returnsNormally);
      final r = await ctl.start(url: 'u', name: 'a', toast: false);
      expect(r, isFalse);
      expect(ctl.taskOf('u'), isNull);
    });

    test('dispose 多次幂等, 不崩', () {
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async =>
            File('/tmp/x'),
      );
      ctl.dispose();
      expect(() => ctl.dispose(), returnsNormally);
      expect(() => ctl.dispose(), returnsNormally);
    });

    test('CR-2026-06 (菜单「保存到下载」复用): 同 URL 两次 start 不并发, downloadFn 只调一次', () async {
      // pane 菜单 _onSaveFile 现在改为调 controller.start, 这条用例验证:
      // 1) 第一次 start 立即触发 downloadFn (UI 立即看到 task downloading);
      // 2) 第二次 start (用户连点) 不重新发起 download。
      final calls = <String>[];
      final block = Completer<File>();
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          calls.add(url);
          return block.future;
        },
      );
      // ignore: discarded_futures
      ctl.start(url: '/chat/media/x/download', name: 'doc.pdf', toast: false);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // 第二次保存同一 URL: controller 内部 fail-fast。
      final second = await ctl.start(
        url: '/chat/media/x/download',
        name: 'doc.pdf',
        toast: false,
      );
      expect(second, isFalse);
      expect(calls, ['/chat/media/x/download']);
      // 收尾。
      block.complete(File('/tmp/x'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ctl.dispose();
    });

    test('start 进行中 → dispose → cancel error 走 catch 分支也不抛', () async {
      final ctl = ChatMediaDownloadController(
        downloadFn: ({
          required String url,
          required String name,
          bool reveal = true,
          bool isImage = false,
          void Function(int, int)? onReceiveProgress,
          CancelToken? cancelToken,
        }) async {
          // 模拟 dispose 触发的 cancelToken.cancel → 抛 DioException(cancel)。
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
          );
        },
      );
      // ignore: discarded_futures
      ctl.start(url: 'u', name: 'a', toast: false);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      ctl.dispose();
      // 等到 fake 抛 cancel; disposed 后 catch 分支 _safeNotify no-op, 不抛 notifier 异常。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ctl.isDisposed, isTrue);
    });
  });
}
