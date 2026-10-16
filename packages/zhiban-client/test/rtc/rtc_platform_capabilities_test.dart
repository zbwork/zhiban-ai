// F16 RTC · RtcPlatformCapabilities 平台能力模型测试。
//
// 纯函数 forPlatform(platform) 的逐平台断言（展示/诊断用，不参与任何 enable/disable 逻辑）。
// 重点：Windows supportsVideoRendering=false 且带 blockedReason；macOS/Android/iOS 视频 true。

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/rtc/rtc_platform_capabilities.dart';

void main() {
  group('RtcPlatformCapabilities.forPlatform', () {
    test('macOS：bridge + 视频 + 屏幕共享均 true，无 blockedReason', () {
      final c = RtcPlatformCapabilities.forPlatform(TargetPlatform.macOS);
      expect(c.supportsNativeBridge, isTrue);
      expect(c.supportsVideoRendering, isTrue);
      expect(c.supportsScreenShare, isTrue);
      expect(c.videoRenderingBlockedReason, isNull);
    });

    test('Android：bridge + 视频 true，屏幕共享 false（deferred），无 video blockedReason',
        () {
      final c = RtcPlatformCapabilities.forPlatform(TargetPlatform.android);
      expect(c.supportsNativeBridge, isTrue);
      expect(c.supportsVideoRendering, isTrue);
      expect(c.supportsScreenShare, isFalse);
      expect(c.videoRenderingBlockedReason, isNull);
    });

    test('iOS：bridge + 视频 true，屏幕共享 false（deferred），无 video blockedReason', () {
      final c = RtcPlatformCapabilities.forPlatform(TargetPlatform.iOS);
      expect(c.supportsNativeBridge, isTrue);
      expect(c.supportsVideoRendering, isTrue);
      expect(c.supportsScreenShare, isFalse);
      expect(c.videoRenderingBlockedReason, isNull);
    });

    test('Windows：bridge + 视频 + 屏幕共享均 true（conditional on SDK），无 blockedReason',
        () {
      final c = RtcPlatformCapabilities.forPlatform(TargetPlatform.windows);
      expect(c.supportsNativeBridge, isTrue);
      expect(c.supportsVideoRendering, isTrue);
      expect(c.supportsScreenShare, isTrue);
      expect(c.videoRenderingBlockedReason, isNull);
    });

    test('其它平台（Linux）：全 false + blockedReason', () {
      final c = RtcPlatformCapabilities.forPlatform(TargetPlatform.linux);
      expect(c.supportsNativeBridge, isFalse);
      expect(c.supportsVideoRendering, isFalse);
      expect(c.supportsScreenShare, isFalse);
      expect(c.videoRenderingBlockedReason, isNotNull);
    });

    test('其它平台（Fuchsia）：全 false', () {
      final c = RtcPlatformCapabilities.forPlatform(TargetPlatform.fuchsia);
      expect(c.supportsNativeBridge, isFalse);
      expect(c.supportsVideoRendering, isFalse);
      expect(c.supportsScreenShare, isFalse);
    });

    test('不可渲染视频的平台才带 blockedReason；可渲染平台 reason 为 null', () {
      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
      ]) {
        expect(
            RtcPlatformCapabilities.forPlatform(p).videoRenderingBlockedReason,
            isNull,
            reason: '$p 支持视频，不应带 blockedReason');
      }
      for (final p in [
        TargetPlatform.linux,
        TargetPlatform.fuchsia
      ]) {
        expect(
            RtcPlatformCapabilities.forPlatform(p).videoRenderingBlockedReason,
            isNotNull,
            reason: '$p 不支持视频渲染，应带 blockedReason');
      }
    });
  });
}
