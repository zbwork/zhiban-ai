import 'dart:io';
import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:zhiban_client/routes/navigation_keys.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/utils/haptic_utils.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

typedef NotificationTapCallback = void Function(String payload);

class AppNotificationService {
  AppNotificationService._();

  static bool _inited = false;
  static bool _isFlashing = false;
  static int _seq = 0;

  static NotificationTapCallback? onNotificationTapped;

  static final MethodChannel _channel =
      MethodChannel('cn.qkfintech.zhiban/notification');

  static Future<void> init() async {
    if (_inited) return;
    if (!PlatformUtils.isDesktop) {
      return;
    }
    await localNotifier.setup(appName: '知办AI');
    _inited = true;
  }

  static Future<void> notify({
    required String title,
    required String body,
    String payload = '',
  }) async {
    if (PlatformUtils.isMobile) {
      unawaited(HapticUtils.mediumImpact());
      if (_isMobileOnChatTab()) return;
      _notifyMobileBanner(title: title, body: body, payload: payload);
      return;
    }
    if (!_inited || !PlatformUtils.isDesktop) return;
    _seq++;
    final notification = LocalNotification(
      identifier: '${payload}_$_seq',
      title: title,
      body: body,
    );
    notification.onClick = () {
      unawaited(_handleClick(payload));
    };
    await notification.show();
  }

  /// 移动端没有系统级"应用内横幅"这回事——原生推送只在 App 被杀/退到后台时
  /// 才会走系统通知中心；App 在前台但停在别的页面（比如在自动任务页收到一条
  /// 对话新消息）时，什么都不会弹，用户完全无感（2026-08-25 反馈）。用
  /// BotToast.showNotification 在应用内顶部弹一条类 iOS 横幅，点击跳转到对应
  /// 会话，效果上补齐前台场景。
  /// 移动端「对话」tab 下(列表页或会话详情页)本身就能直接看到新消息/未读角标，
  /// 应用内横幅纯属多余打扰——只在停在其它 tab(任务/数字员工/通讯录等)时才
  /// 需要横幅补齐前台无感的问题(2026-08-26 反馈)。
  static bool _isMobileOnChatTab() {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return false;
    final router = GoRouter.maybeOf(context);
    final location = router?.state.matchedLocation;
    if (location == null) return false;
    return location == RoutePaths.chat ||
        location.startsWith('${RoutePaths.chat}/');
  }

  static void _notifyMobileBanner({
    required String title,
    required String body,
    String payload = '',
  }) {
    BotToast.showCustomNotification(
      duration: const Duration(seconds: 10),
      align: Alignment.topCenter,
      useSafeArea: true,
      enableSlideOff: true,
      dismissDirections: const [DismissDirection.up],
      toastBuilder: (cancel) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          // 白底卡片跟 App 自身的浅灰底(0xFFEEF0F4)几乎融为一体, Card 默认的
          // elevation 阴影在浅色背景上太淡看不出来——改用明确的描边 + 更重的
          // 阴影, 让横幅从背景里"浮"出来(2026-08-26 反馈)。
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE4E7EC)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33101828),
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            cancel();
            unawaited(_handleClick(payload));
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F1FF),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.chat_bubble,
                    size: 18, color: Color(0xFF3361F0)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1D2939),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF667085)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _handleClick(String payload) async {
    await bringToFront();
    if (payload.isNotEmpty) {
      onNotificationTapped?.call(payload);
    }
  }

  static Future<void> setBadgeCount(int count) async {
    if (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setBadgeCount', {'count': count});
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        if (count > 0) {
          await WindowsTaskbar.setOverlayIcon(
            ThumbnailToolbarAssetIcon('assets/images/badge_unread.ico'),
            tooltip: '$count条未读消息',
          );
        } else {
          await WindowsTaskbar.resetOverlayIcon();
        }
      } catch (_) {}
    }
  }

  static Future<void> flash() async {
    if (!Platform.isWindows || _isFlashing) return;
    _isFlashing = true;
    try {
      await WindowsTaskbar.setFlashTaskbarAppIcon(
        mode: TaskbarFlashMode.all,
        timeout: const Duration(milliseconds: 500),
      );
    } catch (_) {}
  }

  static Future<void> clearAll() async {
    await setBadgeCount(0);
    if (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) {
      try {
        await _channel.invokeMethod('clearNotifications');
      } catch (_) {}
    }
    if (Platform.isWindows && _isFlashing) {
      _isFlashing = false;
      try {
        await WindowsTaskbar.resetFlashTaskbarAppIcon();
      } catch (_) {}
    }
  }

  static Future<void> bringToFront() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }
}
