// agent-bus QR 扫码登录 (docs §10.4)。
//
// 设计:
//   - qrInfoProvider: AsyncNotifierProvider, 启动 / 刷新时调 /auth/qr/create 拉一张新二维码。
//   - qrStatusProvider: AutoDispose StreamProvider, 把当前 key 的 /auth/qr/status 包成 2s 轮询;
//     收到终态 (confirmed / cancelled / expired) 后自动停。
//   - 登录持久化已在 auth_api.qrStatusApi 内做掉; UI 只需要根据 status 判断是否进主页。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';

/// 当前桌面端正在使用的二维码 (Create 一次, 失败/过期后重 refresh 一次)。
/// Riverpod 3 不再区分 AutoDispose 子类型, 这里用普通 AsyncNotifier; logout 时 resetSessionScope
/// 会整体重建 ProviderScope, 不会泄漏 stream。
final qrInfoProvider =
    AsyncNotifierProvider<QrInfoNotifier, QRLoginCreated>(QrInfoNotifier.new);

class QrInfoNotifier extends AsyncNotifier<QRLoginCreated> {
  @override
  Future<QRLoginCreated> build() => createQrApi();

  /// "刷新二维码" 按钮 / 终态后自动调。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(createQrApi);
  }
}

/// 按当前 qrInfo.key 轮询服务端状态。
/// 终态后 stream close, UI 端不会再触发刷新。
final qrStatusProvider =
    StreamProvider.autoDispose<QRLoginStatus>((ref) async* {
  final info = await ref.watch(qrInfoProvider.future);
  if (info.key.isEmpty) return;
  // 立即拉一次, 之后每 2s 一次, 终态停。
  while (true) {
    try {
      final s = await qrStatusApi(info.key);
      yield s;
      if (s.isTerminal) return;
    } catch (_) {
      // 网络错误不抛, 继续轮询; 服务端 5min TTL 内可恢复。
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});
