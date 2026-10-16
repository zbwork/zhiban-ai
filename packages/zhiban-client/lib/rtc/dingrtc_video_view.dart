// F16 · DingRTC 视频画面 widget（跨平台 FlutterPlatformView，统一 viewType "easyo/rtc/video_view"）。
//
// 各平台 native DingRtcVideoViewFactory 返回原生视图并绑定到 DingRtcVideoCanvas
// （local→setLocalViewConfig+startPreview / remote→setRemoteViewConfig+subscribe）：
//   - macOS：AppKitView → NSView（已实现）
//   - Android：AndroidView → SurfaceView（createRenderSurfaceView，已实现）
//   - iOS：UiKitView → UIView（已实现）
//   - Windows：视频画面 blocked（Flutter Windows 无稳定 PlatformView，见 §15.6）→ 返回明确的
//     [RtcWindowsVideoPlaceholder] 提示占位（**非纯黑、不伪造画面、不阻断通话**）。
//
// 其它平台（Linux / Fuchsia 等）/ 单测默认占位 → 中性深色 ColoredBox，**不伪造画面**。
// （Web 无独立 TargetPlatform，运行时按 host OS 命中对应分支；本应用不发布 Web。）

import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart'
    show Factory, defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart'
    show
        AndroidViewController,
        MethodChannel,
        PlatformViewsService,
        StandardMessageCodec;

/// 视频画面角色：本地预览 / 远端摄像头 / 远端屏幕共享。
enum RtcVideoRole { local, remote, remoteScreen }

class DingRtcVideoView extends StatelessWidget {
  const DingRtcVideoView({
    super.key,
    required this.role,
    this.userId,
    this.callUuid,
  });

  /// local = 本地摄像头预览；remote = 远端某 uid 的摄像头；
  /// remoteScreen = 远端某 uid 的屏幕共享。
  final RtcVideoRole role;

  /// 远端画面对应的 DingRTC userId（remote 必填；local 忽略）。
  final String? userId;

  /// 仅用于 native 日志/防串，不含 token。
  final String? callUuid;

  /// 与 native `registrar.register(_, withId:)` 一致的 PlatformView 标识。
  static const String viewType = 'easyo/rtc/video_view';

  /// 传给 native 工厂的 creationParams（纯函数，便于单测 role/userId 映射）。
  Map<String, dynamic> creationParams() => <String, dynamic>{
        'role': switch (role) {
          RtcVideoRole.local => 'local',
          RtcVideoRole.remote => 'remote',
          RtcVideoRole.remoteScreen => 'remoteScreen',
        },
        if (userId != null && userId!.trim().isNotEmpty)
          'userId': userId!.trim(),
        if (callUuid != null && callUuid!.trim().isNotEmpty)
          'callUuid': callUuid!.trim(),
      };

  /// 中性深色占位（不伪造画面）：未实现 native 工厂的平台 + 单测环境用。
  static const Widget _placeholder = ColoredBox(color: Color(0xFF0E0F12));

  /// 仅测试用：强制走中性占位分支。生产恒为 false；widget 测试里挂载真实 PlatformView
  /// （AppKitView/AndroidView）在 flutter_test 下会挂起/超时，故由 test/flutter_test_config.dart
  /// 在测试启动时统一置 true。平台分支选择由 [buildForPlatform] 单测直接覆盖（不挂载）。
  @visibleForTesting
  static bool debugForcePlaceholder = false;

  /// 按目标平台返回真实平台视图或占位。**仅构造 widget、不挂载**，可在单测直接断言返回类型。
  /// 已实现 native bridge 的平台返回真实 PlatformView（同一 viewType + creationParams 协议）；
  /// Windows 视频 blocked → 返回 [RtcWindowsVideoPlaceholder] 明确提示占位；
  /// 其它未实现平台（Linux / Fuchsia 等）返回中性占位 `ColoredBox`，**不伪造画面**。
  @visibleForTesting
  Widget buildForPlatform(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.macOS:
        // macOS：DingRtcVideoViewFactory 返回 NSView。
        return AppKitView(
          viewType: viewType,
          creationParams: creationParams(),
          creationParamsCodec: const StandardMessageCodec(),
        );
      case TargetPlatform.android:
        // Android：DingRtcVideoViewFactory 返回 SurfaceView（createRenderSurfaceView）。
        // 必须用 Hybrid Composition（PlatformViewLink + initExpensiveAndroidView）：默认的
        // AndroidView 走 Virtual Display，抓不到 SurfaceView 的内容 → 黑屏；HC 让原生 SurfaceView
        // 直接进入原生视图层级叠加渲染（DingRTC 仅提供 SurfaceView，无 TextureView 变体）。
        return PlatformViewLink(
          viewType: viewType,
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers:
                const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          ),
          onCreatePlatformView: (params) {
            final controller = PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: creationParams(),
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            );
            controller
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
            return controller;
          },
        );
      case TargetPlatform.iOS:
        // iOS：DingRtcVideoViewFactory 返回 UIView（绑定 DingRtcVideoCanvas）。
        return UiKitView(
          viewType: viewType,
          creationParams: creationParams(),
          creationParamsCodec: const StandardMessageCodec(),
        );
      case TargetPlatform.windows:
        // Windows: HWND child-window overlay — SDK 直接渲染到子窗口。
        return _RtcWindowsNativeVideoView(
          role: role,
          userId: userId,
          callUuid: callUuid,
        );
      default:
        return _placeholder;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (debugForcePlaceholder) return _placeholder;
    return buildForPlatform(defaultTargetPlatform);
  }
}

/// Windows 视频画面占位（**非纯黑块**）。
///
/// Windows 暂无稳定 Flutter PlatformView，视频画面 blocked（见
/// zhiban-app-rtc-cross-platform.md §15.6）。这里给一个克制的深色提示占位，明确告诉用户/测试
/// 「视频渲染未完成」，而不是只显示一块纯黑 [ColoredBox]。
///
/// **不降级语音、不阻断通话、不弹 toast**——音频与通话控制照常（与产品决定一致：不隐藏入口、
/// 不把 video 降级成 audio）。仅在 Windows 视频画面区域出现
/// （[DingRtcVideoView.buildForPlatform] 的 windows 分支）。
///
/// 用 [FittedBox] 缩放兜底：本地 PiP 等小块也不会文字溢出，大画面区按自然尺寸展示。
class RtcWindowsVideoPlaceholder extends StatelessWidget {
  const RtcWindowsVideoPlaceholder({super.key});

  /// 提示主文案（测试稳定断言用）。
  static const String headline = 'Windows 视频画面暂未接通';

  /// 提示副文案：明确「不阻断音频/通话」+「需原生支持」，不暴露 token / 技术细节噪声。
  static const String detail = '音频与通话控制可继续使用，视频渲染需 Windows 原生 HWND 支持';

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0E0F12),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(CupertinoIcons.video_camera,
                      size: 26, color: Color(0xFF8A8F99)),
                  SizedBox(height: 8),
                  Text(
                    headline,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE5E6EB),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: Color(0xFF9AA0AA)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Windows HWND child-window overlay: attaches a native child HWND to the
/// Flutter window, positioned to match this widget's layout rect.
/// The DingRTC SDK renders directly into the child HWND.
class _RtcWindowsNativeVideoView extends StatefulWidget {
  const _RtcWindowsNativeVideoView({
    required this.role,
    this.userId,
    this.callUuid,
  });
  final RtcVideoRole role;
  final String? userId;
  final String? callUuid;

  @override
  State<_RtcWindowsNativeVideoView> createState() =>
      _RtcWindowsNativeVideoViewState();
}

class _RtcWindowsNativeVideoViewState
    extends State<_RtcWindowsNativeVideoView> with WidgetsBindingObserver {
  static const _methods = MethodChannel('easyo/rtc/methods');
  bool _attached = false;
  Rect _lastRect = Rect.zero;

  bool get _isLocal => widget.role == RtcVideoRole.local;

  String get _trackName =>
      widget.role == RtcVideoRole.remoteScreen ? 'screen' : 'camera';

  String get _uid => widget.userId ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachIfReady());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detach();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _RtcWindowsNativeVideoView old) {
    super.didUpdateWidget(old);
    if (old.userId != widget.userId || old.role != widget.role) {
      _detach();
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _attachIfReady());
    }
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateRect());
  }

  Rect? _getRect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    final dpr = ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
    return Rect.fromLTWH(
      topLeft.dx * dpr,
      topLeft.dy * dpr,
      box.size.width * dpr,
      box.size.height * dpr,
    );
  }

  Map<String, dynamic> _rectArgs(Rect rect) => <String, dynamic>{
        'left': rect.left,
        'top': rect.top,
        'width': rect.width,
        'height': rect.height,
      };

  Future<void> _attachIfReady() async {
    if (!mounted) return;
    if (!_isLocal && _uid.isEmpty) return;
    final rect = _getRect();
    if (rect == null || rect.width < 1 || rect.height < 1) return;
    _lastRect = rect;
    try {
      if (_isLocal) {
        await _methods.invokeMethod<int>('attachLocalVideo', _rectArgs(rect));
      } else {
        await _methods.invokeMethod<int>('attachRemoteVideo', <String, dynamic>{
          'uid': _uid,
          'track': _trackName,
          ..._rectArgs(rect),
        });
      }
      _attached = true;
    } catch (e) {
      debugPrint('[F16 RTC] attach video failed: $e');
    }
  }

  Future<void> _updateRect() async {
    if (!mounted || !_attached) return;
    final rect = _getRect();
    if (rect == null) return;
    if ((rect.left - _lastRect.left).abs() < 1 &&
        (rect.top - _lastRect.top).abs() < 1 &&
        (rect.width - _lastRect.width).abs() < 1 &&
        (rect.height - _lastRect.height).abs() < 1) {
      return;
    }
    _lastRect = rect;
    try {
      if (_isLocal) {
        await _methods.invokeMethod<void>('updateLocalVideoRect', _rectArgs(rect));
      } else {
        await _methods.invokeMethod<void>('updateVideoRect', <String, dynamic>{
          'uid': _uid,
          'track': _trackName,
          ..._rectArgs(rect),
        });
      }
    } catch (e) {
      debugPrint('[F16 RTC] updateVideoRect failed: $e');
    }
  }

  void _detach() {
    if (!_attached) return;
    _attached = false;
    if (_isLocal) {
      _methods.invokeMethod<void>('detachLocalVideo').catchError((_) {});
    } else {
      _methods.invokeMethod<void>('detachRemoteVideo', <String, dynamic>{
        'uid': _uid,
        'track': _trackName,
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateRect());
    return const ColoredBox(color: Color(0xFF0E0F12));
  }
}
