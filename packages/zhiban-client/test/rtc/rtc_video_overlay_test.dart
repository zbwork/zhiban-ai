// F16 Phase B · 视频通话浮层 widget 测试（真实画面接线后）。
//
// 覆盖：来电/呼叫视频文案、通话中真实视频面板（远端 DingRtcVideoView + 本地 PiP）、
// 远端未到「等待对方加入」、摄像头开关切「摄像头已关」、audio 不回归、Esc 挂断 / Enter 接听。
//
// DingRtcVideoView 真实画面只在 macOS PlatformView 上渲染；单测强制 target=android →
// DingRtcVideoView 走中性预留态分支（不实例化 AppKitView），但仍可 find.byType 定位。
// **不**断言任何真实视频帧（需两台 Mac 真机），只断言结构与状态。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/contents/wk_rtc_call_signal_content.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/rtc/dingrtc_video_view.dart';
import 'package:zhiban_client/rtc/fake_rtc_client.dart';
import 'package:zhiban_client/rtc/rtc_call_api.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/rtc/rtc_client.dart';
import 'package:zhiban_client/rtc/widgets/rtc_call_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_meeting_window.dart';
import 'fake_tone_player.dart';

/// 返回带 rtc 凭证的 session 的 fake api（永不走网络）。
class _Api extends RtcCallApi {
  _Api() : super(dio: Dio());
  static const _rtc =
      RtcJoinConfig(appId: 'a', channelId: 'rtc_x', userId: 'u', token: 'T');

  @override
  Future<RtcCallSession> createCall({
    required String roomUuid,
    String? calleeAccountUuid,
    String? agentUuid,
    String? conversationUuid,
    String kind = 'audio',
  }) async =>
      const RtcCallSession(
          callUuid: 'call-out',
          state: 'ringing',
          aliyunChannelId: 'rtc_x',
          rtc: _rtc);

  @override
  Future<RtcCallSession> answer(String callUuid) async => const RtcCallSession(
      callUuid: 'call-in',
      state: 'active',
      aliyunChannelId: 'rtc_x',
      rtc: _rtc);

  @override
  Future<void> reject(String callUuid) async {}
  @override
  Future<void> cancel(String callUuid) async {}
  @override
  Future<void> leave(String callUuid) async {}
}

class _Harness {
  _Harness()
      : client = FakeRtcClient(),
        signals = StreamController<RtcCallSignalIncoming>.broadcast() {
    controller = RtcCallController(
      api: _Api(),
      clientFactory: () => client,
      signalStream: signals.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
    );
  }
  final FakeRtcClient client;
  final StreamController<RtcCallSignalIncoming> signals;
  late final RtcCallController controller;

  void dispose() {
    controller.dispose();
    signals.close();
  }
}

RtcCallSignalIncoming _invite({String kind = 'audio'}) => RtcCallSignalIncoming(
      messageId: 'm',
      fromUid: 'peer',
      channelId: 't_7_d_room',
      channelType: 2,
      timestamp: 0,
      event: RtcCallSignalEvent.invite,
      data: <String, dynamic>{'call_uuid': 'call-in', 'kind': kind},
    );

Future<void> _pumpOverlay(WidgetTester tester, RtcCallController c,
    {double inset = 0}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [rtcCallControllerProvider.overrideWithValue(c)],
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [RtcCallOverlayHost(desktopContentLeftInset: inset)],
        ),
      ),
    ),
  ));
}

/// 进入「视频通话中」：发起 video → 远端入会 → active（remoteUserId 已知）。
Future<void> _reachActiveVideo(WidgetTester tester, _Harness h) async {
  await h.controller.startOutgoing(
      roomUuid: 'r', calleeAccountUuid: 'c', mediaKind: RtcMediaKind.video);
  h.client.simulateRemoteUserJoined('peer');
  await tester.pump();
  await tester.pump();
}

/// 进入「视频接通中」：来电 video → 接听 → connecting（remoteUserId 仍 null）。
Future<void> _reachConnectingVideo(WidgetTester tester, _Harness h) async {
  h.signals.add(_invite(kind: 'video'));
  await tester.pump();
  await tester.pump();
  await h.controller.acceptIncoming();
  await tester.pump();
  await tester.pump();
}

// flutter_test 默认 target=android（≠ macOS）→ DingRtcVideoView 走中性预留态分支，
// 不实例化真实 AppKitView 平台视图，但仍可 find.byType 定位。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('incoming video overlay：副标题/接听拒接按钮', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    h.signals.add(_invite(kind: 'video'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('邀请你进行视频通话'), findsOneWidget);
    expect(find.byTooltip('接听'), findsOneWidget);
    expect(find.byTooltip('拒接'), findsOneWidget);
  });

  testWidgets('outgoing video overlay：正在发起视频通话', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await h.controller.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'c', mediaKind: RtcMediaKind.video);
    await tester.pump();

    expect(find.textContaining('正在发起视频通话'), findsOneWidget);
    expect(find.byTooltip('取消'), findsOneWidget);
  });

  testWidgets('active video：远端 DingRtcVideoView + 本地 PiP + 控制条',
      (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    expect(h.controller.phase, RtcCallPhase.active);
    expect(h.controller.remoteUserId, 'peer');
    // 远端主画面 + 本地 PiP 各一个真实 DingRtcVideoView（不再是「待联调」预留态）。
    expect(find.byType(DingRtcVideoView), findsNWidgets(2));
    expect(find.text('视频画面待联调'), findsNothing);
    expect(find.text('视频通话'), findsOneWidget); // 面板左上标题
    // 控制条：静音 / 摄像头（开 → 关闭摄像头）/ 挂断 全可用。
    expect(find.byTooltip('静音'), findsOneWidget);
    expect(find.byTooltip('关闭摄像头'), findsOneWidget);
    expect(find.byTooltip('挂断'), findsOneWidget);
  });

  testWidgets('connecting video：接通前是小卡（接通中），未进会议窗口', (tester) async {
    // 统一会议模型：仅 active（远端已入会）才进会议窗口；connecting 仍是呼叫态小卡。
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachConnectingVideo(tester, h);

    expect(h.controller.phase, RtcCallPhase.connecting);
    expect(h.controller.remoteUserId, isNull);
    expect(find.textContaining('接通中'), findsOneWidget); // 小卡状态文案
    // 会议壳尚未挂载 → 无视频画面、无「等待对方加入」舞台。
    expect(find.byType(DingRtcVideoView), findsNothing);
    expect(find.text('等待对方加入'), findsNothing);
  });

  testWidgets('摄像头开关：关闭后本地 PiP 显示「摄像头已关」', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);
    expect(h.controller.cameraOn, isTrue);

    await tester.tap(find.byTooltip('关闭摄像头'));
    await tester.pump();
    await tester.pump();

    expect(h.controller.cameraOn, isFalse);
    expect(find.text('摄像头已关'), findsOneWidget);
    expect(find.byTooltip('开启摄像头'), findsOneWidget);
    // 关摄像头后本地块改为头像预留态（不伪造画面）→ 仅远端一个 DingRtcVideoView。
    expect(find.byType(DingRtcVideoView), findsOneWidget);
  });

  testWidgets('audio 不回归：来电话术正确 + 通话中无视频面板/无 DingRtcVideoView', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);

    h.signals.add(_invite(kind: 'audio'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('邀请你进行语音通话'), findsOneWidget);
    expect(find.textContaining('邀请你进行视频通话'), findsNothing);

    await h.controller.rejectIncoming();
    await tester.pump();
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    h.client.simulateRemoteUserJoined('peer');
    await tester.pump();
    await tester.pump();
    expect(h.controller.isVideo, isFalse);
    expect(find.byType(DingRtcVideoView), findsNothing); // 音频通话无视频画面
    expect(find.text('等待对方加入'), findsNothing);
    expect(find.byTooltip('挂断'), findsOneWidget); // 顶部条挂断仍在
  });

  testWidgets('Esc 在 active video 中挂断', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);
    expect(h.controller.phase, RtcCallPhase.active);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, RtcCallPhase.idle);
  });

  testWidgets('Enter 在 incoming video 中接听', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    h.signals.add(_invite(kind: 'video'));
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, RtcCallPhase.incomingRinging);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase,
        anyOf(RtcCallPhase.connecting, RtcCallPhase.active));
  });

  // ───── 主叫居中（内容区）+ 可拖动 ─────

  testWidgets('outgoing audio：呼叫卡落聊天内容区居中（非全窗居中）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller, inset: 416);
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    await tester.pump();

    final cardX = tester.getCenter(find.text('正在发起语音通话')).dx;
    // 全窗中心 600；内容区 [428,1188] 中心≈808 → 卡片明显在内容区中心、不在全窗中心。
    expect(cardX, greaterThan(700));
  });

  testWidgets('呼叫卡可拖动：拖拽后位置改变，新通话恢复默认', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller, inset: 416);
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    await tester.pump();

    final before = tester.getCenter(find.text('正在发起语音通话'));
    await tester.drag(find.text('正在发起语音通话'), const Offset(-80, -40));
    await tester.pump();
    final after = tester.getCenter(find.text('正在发起语音通话'));
    expect(after.dx, lessThan(before.dx)); // 已左移
    expect(after, isNot(before));

    // 结束 → 新通话 → 位移复位（DraggableCallSurface 重新挂载）。
    await h.controller.cancelOutgoing();
    await tester.pump();
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    await tester.pump();
    final reset = tester.getCenter(find.text('正在发起语音通话'));
    expect((reset.dx - before.dx).abs(), lessThan(1.0)); // 恢复默认位置
  });

  testWidgets('拖动卡片上的按钮仍可点击（取消生效，不被拖拽吞掉）', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller, inset: 416);
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    await tester.pump();
    await tester.tap(find.byTooltip('取消'));
    await tester.pump();
    expect(h.controller.phase, RtcCallPhase.idle); // 点击生效
  });

  // ───── 飞书质感位置：来电卡 / 呼叫卡 / 通话条 ─────

  testWidgets('incoming audio：来电卡含语音副标题 + 红拒接 + 绿接听', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    h.signals.add(_invite(kind: 'audio'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('邀请你进行语音通话'), findsOneWidget);
    expect(find.byTooltip('拒接'), findsOneWidget);
    expect(find.byTooltip('接听'), findsOneWidget);
  });

  testWidgets('outgoing audio：竖向呼叫卡（正在发起语音通话 + 取消），非顶部 bar', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    await tester.pump();

    expect(h.controller.phase, RtcCallPhase.outgoingRinging);
    expect(find.textContaining('正在发起语音通话'), findsOneWidget);
    // 竖向卡片在按钮下方有「取消」文字标签（旧顶部横条只有 tooltip，无此 Text）。
    expect(find.text('取消'), findsOneWidget);
    expect(find.byTooltip('取消'), findsOneWidget);
    expect(find.byType(DingRtcVideoView), findsNothing); // 语音通话无视频画面
  });

  testWidgets('active audio（app fallback）：进会议壳但 tile 为头像预留态、无视频画面',
      (tester) async {
    // 统一会议模型：audio 接通也进同一会议壳（native 失败 fallback）；audio = cameraOff 的会议，
    // tile 显示头像预留态、绝不伪造视频。控制条 mic/挂断真实。
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await h.controller.startOutgoing(roomUuid: 'r', calleeAccountUuid: 'c');
    h.client.simulateRemoteUserJoined('peer');
    await tester.pump();
    await tester.pump();

    expect(h.controller.phase, RtcCallPhase.active);
    expect(h.controller.isVideo, isFalse);
    expect(h.controller.nativeMeetingVisible, isFalse); // Noop → app 壳 fallback
    expect(find.byTooltip('静音'), findsOneWidget);
    expect(find.byTooltip('挂断'), findsOneWidget);
    expect(find.byType(DingRtcVideoView), findsNothing); // 头像预留态，不伪造视频
  });

  testWidgets('native 会议窗显示时：主应用只剩轻量状态条（回到会议窗口）', (tester) async {
    // 注入 FakeMeetingWindow(shown:true) → nativeMeetingVisible=true → app 内不渲染会议壳，
    // 仅显示「视频通话中 + 回到会议窗口 + 挂断」状态条（不伪造视频画面）。
    final mw = FakeMeetingWindow(shown: true);
    final client = FakeRtcClient();
    final signals = StreamController<RtcCallSignalIncoming>.broadcast();
    final controller = RtcCallController(
      api: _Api(),
      clientFactory: () => client,
      signalStream: signals.stream,
      selfUid: () => 'me',
      showToast: (_) {},
      tonePlayer: FakeTonePlayer(),
      nativeMeetingWindow: mw,
    );
    addTearDown(() {
      controller.dispose();
      signals.close();
    });
    await _pumpOverlay(tester, controller);
    await controller.startOutgoing(
        roomUuid: 'r', calleeAccountUuid: 'c', mediaKind: RtcMediaKind.video);
    client.simulateRemoteUserJoined('peer');
    await tester.pump();
    await tester.pump();

    expect(controller.nativeMeetingVisible, isTrue);
    expect(find.text('视频通话中'), findsOneWidget); // 状态条
    expect(find.byTooltip('回到会议窗口'), findsOneWidget);
    expect(find.byTooltip('挂断'), findsOneWidget);
    // 会议壳/视频画面交给原生窗 → app 内不渲染。
    expect(find.byType(DingRtcVideoView), findsNothing);
    expect(find.byTooltip('参会人'), findsNothing);
  });

  // ───── 视频会议壳：标题栏 / 控制条 / 参会人 / 布局 / 可拖动 ─────

  testWidgets('meeting shell：标题栏 + 控制条（真实 + disabled 预留态）', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    // 标题栏：会议信息 + 切换布局/还原位置/结束。
    expect(find.text('视频通话'), findsOneWidget);
    expect(find.byTooltip('切换布局'), findsOneWidget);
    expect(find.byTooltip('还原位置'), findsOneWidget);
    expect(find.byTooltip('结束通话'), findsOneWidget);
    // 控制条真实：mic/camera/hangup/参会人/邀请。
    expect(find.byTooltip('静音'), findsOneWidget);
    expect(find.byTooltip('关闭摄像头'), findsOneWidget);
    expect(find.byTooltip('挂断'), findsOneWidget);
    expect(find.byTooltip('参会人'), findsOneWidget);
    expect(find.byTooltip('邀请'), findsOneWidget);
    // disabled 预留态（暂未支持）。
    expect(find.byTooltip('共享屏幕 · 暂未支持'), findsOneWidget);
    expect(find.byTooltip('录制 · 暂未支持'), findsOneWidget);
    expect(find.byTooltip('AI 总结 · 暂未支持'), findsOneWidget);
    expect(find.byTooltip('字幕 · 暂未支持'), findsOneWidget);
    expect(find.byTooltip('更多 · 暂未支持'), findsOneWidget);
  });

  testWidgets('meeting：mic/camera/hangup 调用 controller', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(h.controller.muted, isTrue);

    await tester.tap(find.byTooltip('关闭摄像头'));
    await tester.pump();
    expect(h.controller.cameraOn, isFalse);

    await tester.tap(find.byTooltip('挂断'));
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, RtcCallPhase.idle);
  });

  testWidgets('meeting：disabled 功能点击不触发假业务', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    await tester.tap(find.byTooltip('共享屏幕 · 暂未支持'));
    await tester.tap(find.byTooltip('录制 · 暂未支持'));
    await tester.tap(find.byTooltip('字幕 · 暂未支持'));
    await tester.pump();
    expect(h.controller.phase, RtcCallPhase.active); // 无副作用，仍在通话
  });

  testWidgets('meeting：app 内设备下拉可选择摄像头/音频路由', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    expect(h.client.currentDevice(RtcDeviceKind.camera), 'cam-a');
    await tester.tap(find.byTooltip('摄像头设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cam-b name'));
    await tester.pumpAndSettle();
    expect(h.client.currentDevice(RtcDeviceKind.camera), 'cam-b');

    expect(h.client.currentDevice(RtcDeviceKind.speaker), 'spk-a');
    await tester.tap(find.byTooltip('音频设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('spk-b name'));
    await tester.pumpAndSettle();
    expect(h.client.currentDevice(RtcDeviceKind.speaker), 'spk-b');
  });

  testWidgets('meeting：参会人 panel 打开 / 关闭', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    expect(find.text('参会人 (2)'), findsNothing);
    await tester.tap(find.byTooltip('参会人'));
    await tester.pump();
    expect(find.text('参会人 (2)'), findsOneWidget); // 1v1 → 我 + 对方
    await tester.tap(find.byTooltip('收起'));
    await tester.pump();
    expect(find.text('参会人 (2)'), findsNothing);
  });

  testWidgets('meeting：布局切换 gallery↔speaker（本地块尺寸变化）', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    final gallery = tester.getSize(find.byKey(const ValueKey('tile-local')));
    await tester.tap(find.byTooltip('切换布局'));
    await tester.pump();
    final speaker = tester.getSize(find.byKey(const ValueKey('tile-local')));
    expect(speaker.width, lessThan(gallery.width)); // speaker 下本地变 PiP
  });

  testWidgets('meeting：邀请打开 scaffold（分享 disabled）', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller);
    await _reachActiveVideo(tester, h);

    await tester.tap(find.byTooltip('邀请'));
    await tester.pump();
    await tester.pump(const Duration(
        milliseconds: 350)); // 等弹窗过场（不 pumpAndSettle：时长 Timer 不settle）
    expect(find.textContaining('多人邀请待后续接入'), findsOneWidget);
    // 分享按钮 disabled（onPressed: null）。
    final share = tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '分享'));
    expect(share.onPressed, isNull);
  });

  testWidgets('meeting：可拖动（标题栏）+ 还原位置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    addTearDown(h.dispose);
    await _pumpOverlay(tester, h.controller, inset: 416);
    await _reachActiveVideo(tester, h);

    final before = tester.getCenter(find.byKey(const ValueKey('tile-local')));
    await tester.drag(find.text('视频通话'), const Offset(0, -80)); // 拖标题栏上移
    await tester.pump();
    final after = tester.getCenter(find.byKey(const ValueKey('tile-local')));
    expect(after.dy, lessThan(before.dy)); // 已上移
    expect(after, isNot(before));

    await tester.tap(find.byTooltip('还原位置'));
    await tester.pump();
    final reset = tester.getCenter(find.byKey(const ValueKey('tile-local')));
    expect((reset.dy - before.dy).abs(), lessThan(1.0)); // 恢复默认
  });
}
