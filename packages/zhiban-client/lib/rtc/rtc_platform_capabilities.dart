// F16 RTC · 跨平台能力模型（**仅用于提示 / 展示 / 诊断，绝不用于隐藏或禁用呼叫入口**）。
//
// 这是一个按 [TargetPlatform] 静态描述「该平台 RTC 设计 / 目标能力」的只读模型，供 UI 给用户 /
// 测试人员展示「为什么 Windows 视频画面暂未接通」之类提示，或用于诊断日志。
//
// **它不参与任何 enable/disable / 隐藏逻辑**：呼叫入口、视频按钮、摄像头开关一律不依赖本模型
// 置灰或隐藏（产品决定：Windows 视频入口保留、不降级语音）。它只是「能力说明」，不是「能力门控」。
//
// 本轮作为**可复用的展示 / 诊断模型独立交付**，尚未接入具体 UI 消费方；[RtcWindowsVideoPlaceholder]
// 的提示文案刻意独立维护（面向用户的友好措辞），不从本模型的 [videoRenderingBlockedReason]（偏诊断）派生。
//
// 注意：本模型是**平台静态描述**，不是运行时探针。例如 Windows 的 native bridge 仅在构建时编入
// 本地 DingRTC SDK 才存在（否则运行期 `MissingPluginException`）——这点运行时无法静态判断，故
// [supportsNativeBridge] 表示「该平台已实现 / 规划 bridge（conditional on SDK）」的目标态，
// 不代表当前进程一定可用。视频渲染 blocker 详情见
// docs/architecture/zhiban-app-rtc-cross-platform.md（§15.6 / B6）。

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, immutable, TargetPlatform;

@immutable
class RtcPlatformCapabilities {
  const RtcPlatformCapabilities({
    required this.supportsNativeBridge,
    required this.supportsVideoRendering,
    required this.supportsScreenShare,
    this.videoRenderingBlockedReason,
  });

  /// 该平台是否已实现 / 规划同名 `easyo/rtc/methods`+`easyo/rtc/events` native DingRTC bridge。
  /// Windows 为 conditional-on-SDK 的目标态（见文件头注），不代表当前进程一定已编入 SDK。
  final bool supportsNativeBridge;

  /// 该平台是否能真实渲染本地 / 远端视频画面（PlatformView 或等价方案已落地）。
  final bool supportsVideoRendering;

  /// 该平台是否支持屏幕共享。
  final bool supportsScreenShare;

  /// 当 [supportsVideoRendering] 为 false 时，给用户 / 诊断的原因（可直接展示）；否则 null。
  final String? videoRenderingBlockedReason;

  /// 当前运行平台的能力（基于 [defaultTargetPlatform]）。
  static RtcPlatformCapabilities get current =>
      forPlatform(defaultTargetPlatform);

  /// 按平台返回能力模型（纯函数，便于单测）。
  static RtcPlatformCapabilities forPlatform(TargetPlatform platform) {
    switch (platform) {
      // macOS：bridge + 视频渲染 + 屏幕共享均已落地（现状能力）。
      case TargetPlatform.macOS:
        return const RtcPlatformCapabilities(
          supportsNativeBridge: true,
          supportsVideoRendering: true,
          supportsScreenShare: true,
        );
      // Android：bridge + 视频渲染已落地；屏幕共享 deferred。
      case TargetPlatform.android:
        return const RtcPlatformCapabilities(
          supportsNativeBridge: true,
          supportsVideoRendering: true,
          supportsScreenShare: false,
        );
      // iOS：bridge + 视频渲染已落地；屏幕共享 deferred。
      case TargetPlatform.iOS:
        return const RtcPlatformCapabilities(
          supportsNativeBridge: true,
          supportsVideoRendering: true,
          supportsScreenShare: false,
        );
      // Windows：methods/events bridge + HWND overlay 视频渲染 + 屏幕共享均已实现
      // （conditional on 本地 SDK 编入）。
      case TargetPlatform.windows:
        return const RtcPlatformCapabilities(
          supportsNativeBridge: true,
          supportsVideoRendering: true,
          supportsScreenShare: true,
        );
      // 其它（Linux / Fuchsia）：当前无 native RTC 实现。
      // （Web 无独立 TargetPlatform，运行时按 host OS 命中对应分支；本应用不发布 Web。）
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return const RtcPlatformCapabilities(
          supportsNativeBridge: false,
          supportsVideoRendering: false,
          supportsScreenShare: false,
          videoRenderingBlockedReason: '该平台暂无 native RTC 实现。',
        );
    }
  }
}
