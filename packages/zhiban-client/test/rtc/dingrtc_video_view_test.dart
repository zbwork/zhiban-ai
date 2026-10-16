// F16 · DingRtcVideoView 参数 + 跨平台分支选择测试。
//
// creationParams 是纯映射，断言 local/remote role + userId 透传。
// 平台分支选择用 buildForPlatform(platform) **仅构造、不挂载**来断言：
//   - macOS  → AppKitView（已实现 native bridge）
//   - Android → PlatformViewLink（Hybrid Composition 包 SurfaceView）
//   - iOS → UiKitView（已实现 native bridge）
//   - Windows → HWND child-window overlay（SDK 直渲到子窗口）。
//   - 其它（Web 等）→ 中性占位 ColoredBox。
// 注意：flutter_test 下挂载真实 AppKitView/AndroidView/UiKitView 会挂起/超时，故不 pumpWidget 真实平台视图；
// build() 在测试环境（test/flutter_test_config.dart 置 debugForcePlaceholder=true）恒为占位。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/rtc/dingrtc_video_view.dart';

void main() {
  group('DingRtcVideoView.creationParams', () {
    test('local role → role=local, 无 userId', () {
      final p =
          const DingRtcVideoView(role: RtcVideoRole.local).creationParams();
      expect(p['role'], 'local');
      expect(p.containsKey('userId'), isFalse);
    });

    test('remote role + userId → role=remote + userId 透传', () {
      final p = const DingRtcVideoView(
        role: RtcVideoRole.remote,
        userId: 't_7_u_peer',
        callUuid: 'call-1',
      ).creationParams();
      expect(p['role'], 'remote');
      expect(p['userId'], 't_7_u_peer');
      expect(p['callUuid'], 'call-1');
    });

    test('remote 无 userId → userId 省略（不传空串）', () {
      final p =
          const DingRtcVideoView(role: RtcVideoRole.remote).creationParams();
      expect(p['role'], 'remote');
      expect(p.containsKey('userId'), isFalse);
    });

    test('viewType 与 native registrar id 一致', () {
      expect(DingRtcVideoView.viewType, 'easyo/rtc/video_view');
    });
  });

  group('DingRtcVideoView.buildForPlatform 平台分支选择（仅构造、不挂载）', () {
    const view = DingRtcVideoView(role: RtcVideoRole.local);

    test('macOS → AppKitView', () {
      expect(view.buildForPlatform(TargetPlatform.macOS), isA<AppKitView>());
    });

    test('Android → PlatformViewLink（Hybrid Composition，SurfaceView 渲染）', () {
      expect(view.buildForPlatform(TargetPlatform.android),
          isA<PlatformViewLink>());
    });

    test('iOS → UiKitView', () {
      expect(view.buildForPlatform(TargetPlatform.iOS), isA<UiKitView>());
    });

    test('Windows → native HWND overlay widget (not placeholder)', () {
      final w = view.buildForPlatform(TargetPlatform.windows);
      expect(w, isNot(isA<RtcWindowsVideoPlaceholder>()));
      expect(w, isNot(isA<AppKitView>()));
      expect(w, isNot(isA<AndroidView>()));
      expect(w, isNot(isA<UiKitView>()));
    });

    test('其它平台（Linux 等）→ 中性占位 ColoredBox', () {
      expect(view.buildForPlatform(TargetPlatform.linux), isA<ColoredBox>());
    });
  });

  // 测试环境（flutter_test_config 置 debugForcePlaceholder=true）下 build() 恒为占位，
  // 不挂载任何真实平台视图（否则 widget 测试会挂起）。
  testWidgets('build() 在测试环境恒为中性占位，不挂载 AndroidView/AppKitView', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 100,
          height: 100,
          child: DingRtcVideoView(role: RtcVideoRole.local),
        ),
      ),
    ));
    expect(find.byType(DingRtcVideoView), findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byType(AppKitView), findsNothing);
  });

  group('RtcWindowsVideoPlaceholder（Windows 视频 blocked 提示占位）', () {
    testWidgets('渲染明确提示文案（非纯黑），不挂载任何平台视图', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 240,
            child: RtcWindowsVideoPlaceholder(),
          ),
        ),
      ));
      expect(find.text(RtcWindowsVideoPlaceholder.headline), findsOneWidget);
      expect(find.text(RtcWindowsVideoPlaceholder.detail), findsOneWidget);
      expect(find.byType(AndroidView), findsNothing);
      expect(find.byType(AppKitView), findsNothing);
      expect(find.byType(UiKitView), findsNothing);
    });

    testWidgets('小尺寸 / 极端宽高比 tile 不溢出（FittedBox 兜底），文案仍在', (tester) async {
      Future<void> pumpAt(double w, double h) => tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: w,
                  height: h,
                  child: const RtcWindowsVideoPlaceholder(),
                ),
              ),
            ),
          ));
      // 本地 PiP 尺寸：headline + detail 都在，且不抛 overflow。
      await pumpAt(120, 90);
      expect(tester.takeException(), isNull);
      expect(find.text(RtcWindowsVideoPlaceholder.headline), findsOneWidget);
      expect(find.text(RtcWindowsVideoPlaceholder.detail), findsOneWidget);
      // 极端宽扁：FittedBox(scaleDown) 等比缩放，仍不抛 RenderFlex overflow。
      await pumpAt(200, 36);
      expect(tester.takeException(), isNull);
      expect(find.text(RtcWindowsVideoPlaceholder.headline), findsOneWidget);
    });
  });
}
