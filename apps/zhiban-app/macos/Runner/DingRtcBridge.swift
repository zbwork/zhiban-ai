// F16 · DingRTC macOS native bridge (1v1 人↔人 音频 + 视频)。
//
// Dart 侧 lib/rtc/dingrtc_client.dart 通过两个平台通道驱动本桥:
//   - MethodChannel "easyo/rtc/methods": 命令 (initialize/joinChannel/leaveChannel/setMicrophoneMuted/setCameraEnabled/dispose)
//   - EventChannel  "easyo/rtc/events" : 事件 (joined/left/error/remoteUserJoined/remoteUserLeft)
// 视频画面通过 FlutterPlatformView (id "easyo/rtc/video_view", DingRtcVideoViewFactory) 渲染:
//   - 本地预览: setLocalViewConfig(canvas, for: .camera) + startPreview
//   - 远端画面: setRemoteViewConfig(canvas, uid:, for: .camera) + subscribeRemoteVideoStream
//   canvas.view = Flutter 平台视图返回的 NSView (DingRtcOSView == NSView, 见 DingRtcEngineTypes.h)。
//
// 真实接 DingRTC.framework (vendored, 见 Frameworks/DingRTC)。**不**是 FakeRtcClient。
// joinChannel 所需 token 由后端 /api/agent-bus/v1/calls 下发 (DingRTC AppToken), 客户端不自造。

import Cocoa
import CoreGraphics
import DingRTC
import FlutterMacOS

final class DingRtcBridge: NSObject, FlutterStreamHandler, DingRtcEngineDelegate {
  // 静态持有, 保证桥与通道生命周期与 window 一致。
  private static var instance: DingRtcBridge?
  private static var methodChannel: FlutterMethodChannel?
  private static var eventChannel: FlutterEventChannel?

  private var engine: DingRtcEngine?
  private var eventSink: FlutterEventSink?
  // 本通话是否视频。video join 时由 native 负责开摄像头 + 发布本地视频 + 订阅远端视频
  // (单一责任: Dart 不在 join 后重复 enable; 仅摄像头开关按钮调 setCameraEnabled)。
  private var wantsVideo = false
  // 视频平台视图 (PlatformView 提供的 NSView) → DingRtcVideoCanvas 绑定句柄。
  private var localVideoView: NSView?
  private var remoteVideoViews: [String: NSView] = [:]
  private var remoteScreenVideoViews: [String: NSView] = [:]
  // 屏幕共享：最近一次枚举的 source → 类型（desktop/window），供 start 时选 desktopId/windowId。
  private var screenSourceTypes: [String: DingRtcScreenShareType] = [:]
  private var screenSharing = false
  // F16 Phase 0: RTM 智能体控制层 (sendInterrupt/PushToTalk + state/transcription)。
  // rtmClient/rtmAgentClient 在 joinChannel 成功后获取; agentSessionId/agentId 由回调填充,
  // 供后续 Phase 的 sendInterrupt/sendPushToTalk 使用 (空 = 握手未完成, 控制信令不可发)。
  private var rtmClient: DingRtmClient?
  private var rtmAgentClient: DingRtmAgentClient?
  private var agentSessionId: String?
  private var agentUserId: String?

  /// 共享 DingRtcEngine（独立会议窗口复用同一引擎绑定其内的 NSView，**不新建第二套 engine**）。
  static func sharedEngine() -> DingRtcEngine? { return instance?.engine }

  // F16 v0.7 会中讨论: 当前频道/用户 (joinChannel 时写入), 供会议窗口派生 RTM 讨论 session。
  private(set) static var currentChannelId: String?
  private(set) static var currentUserId: String?

  /// 加入(不存在则创建) RTM session — 会中讨论用。rc 0=受理。
  static func rtmJoinSession(_ sessionId: String) -> Int32 {
    guard let rtm = instance?.rtmClient else { return -1 }
    return rtm.joinSession(sessionId)
  }

  /// 向 RTM session 广播消息 (UTF-8 JSON)。
  static func rtmBroadcast(_ sessionId: String, data: Data) -> Int32 {
    guard let rtm = instance?.rtmClient else { return -1 }
    return rtm.broadcastData(sessionId, data: data)
  }

  static func rtmLeaveSession(_ sessionId: String) {
    _ = instance?.rtmClient?.leaveSession(sessionId)
  }

  /// 供独立会议窗口把其内部 NSView 绑定到**同一** engine —— 复用既有单一绑定路径
  /// （含 rc 错误上报 / startPreview / 远端订阅），不新建第二套 engine。
  /// role: local / remote / remoteScreen。会议窗口成为画面句柄的权威来源。
  static func bindMeetingVideoView(_ view: NSView, role: String, userId: String?) {
    instance?.bindVideoView(view, role: role, userId: userId)
  }

  /// 在 MainFlutterWindow.awakeFromNib 里调用一次。
  static func register(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
    let bridge = DingRtcBridge()
    let methods = FlutterMethodChannel(name: "easyo/rtc/methods", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in
      bridge.handle(call, result: result)
    }
    let events = FlutterEventChannel(name: "easyo/rtc/events", binaryMessenger: messenger)
    events.setStreamHandler(bridge)

    // 视频画面 PlatformView 工厂 (FlutterPlatformViewFactory, 见 FlutterPlatformViews.h)。
    let videoFactory = DingRtcVideoViewFactory(bridge: bridge)
    registrar.register(videoFactory, withId: "easyo/rtc/video_view")

    instance = bridge
    methodChannel = methods
    eventChannel = events
  }

  // MARK: - 视频画面绑定 (PlatformView NSView ↔ DingRtcVideoCanvas)

  /// PlatformView 工厂创建 NSView 后回调: 记录并 (engine 就绪时) 绑定到 DingRTC canvas。
  func bindVideoView(_ view: NSView, role: String, userId: String?) {
    if role == "local" {
      localVideoView = view
      applyLocalView()
    } else if role == "remoteScreen", let uid = userId, !uid.isEmpty {
      remoteScreenVideoViews[uid] = view
      applyRemoteScreenView(uid: uid)
    } else if let uid = userId, !uid.isEmpty {
      remoteVideoViews[uid] = view
      applyRemoteView(uid: uid)
    }
  }

  private func makeCanvas(_ view: NSView, renderMode: DingRtcRenderMode = .crop) -> DingRtcVideoCanvas {
    let canvas = DingRtcVideoCanvas()
    canvas.view = view  // DingRtcOSView == NSView
    canvas.renderMode = renderMode
    return canvas
  }

  /// 本地预览: 绑定 view + startPreview (engine/view 任一未就绪则等下次触发)。
  /// rc 非 0 → emit error 事件（异步路径，无同步返回码可借）。
  private func applyLocalView() {
    guard let engine = engine, let view = localVideoView else { return }
    emitVideoSetupError("setLocalViewConfig", engine.setLocalViewConfig(makeCanvas(view), for: .camera))
    emitVideoSetupError("startPreview", engine.startPreview())
  }

  /// 远端画面: 绑定 view + 订阅该 uid 摄像头流。rc 非 0 → emit error 事件。
  private func applyRemoteView(uid: String) {
    guard let engine = engine, let view = remoteVideoViews[uid] else { return }
    _ = engine.setRemoteViewConfig(nil, uid: uid, for: .screen)
    emitVideoSetupError("setRemoteViewConfig", engine.setRemoteViewConfig(makeCanvas(view), uid: uid, for: .camera))
    emitVideoSetupError("subscribeRemoteVideoStream", engine.subscribeRemoteVideoStream(uid, track: .camera, sub: true))
  }

  /// 远端屏幕共享画面：绑定 screen track + 主动订阅该 uid 的屏幕流。
  private func applyRemoteScreenView(uid: String) {
    guard let engine = engine, let view = remoteScreenVideoViews[uid] else { return }
    _ = engine.setRemoteViewConfig(nil, uid: uid, for: .camera)
    // Screen share should preserve full content; camera tiles use crop.
    emitVideoSetupError("setRemoteScreenViewConfig", engine.setRemoteViewConfig(makeCanvas(view, renderMode: .fill), uid: uid, for: .screen))
    emitVideoSetupError("subscribeRemoteScreenStream", engine.subscribeRemoteVideoStream(uid, track: .screen, sub: true))
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ payload: [String: Any]) {
    // FlutterEventSink 必须在平台线程回调。
    DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }
  }

  private func rtcLog(_ message: String) {
    NSLog("[F16 RTC Native] \(message)")
  }

  /// 返回首个非 0 rc（视频建立期聚合多步 rc，便于同步返回给 Dart 判失败）。
  private func firstNonZeroRc(_ rcs: Int32...) -> Int32 {
    for rc in rcs where rc != 0 { return rc }
    return 0
  }

  /// 视频步骤 rc 非 0 → emit error 事件（含 operation + rc，**不含 token**）。
  /// 用于无同步返回码可借的异步路径（view 绑定 / 预览 / 远端订阅）。
  private func emitVideoSetupError(_ operation: String, _ rc: Int32) {
    if rc != 0 {
      rtcLog("video setup failed operation=\(operation) rc=\(rc)")
      emit(["type": "error", "code": Int(rc), "message": "\(operation) rc=\(rc)"])
    }
  }

  /// 释放本地视频采集/预览 + 解绑所有视频画面，确保挂断/dispose 后摄像头熄灭、view 不悬挂。
  /// 幂等「关到底」(已确认 API，best-effort，rc 忽略)。**本地 view 句柄无论 engine 是否在都清空**，
  /// 避免 engine 提前销毁时残留悬挂引用。
  private func releaseVideoCapture() {
    rtcLog("release video capture screenSharing=\(screenSharing) remoteVideoViews=\(remoteVideoViews.count) remoteScreenViews=\(remoteScreenVideoViews.count)")
    if let engine = engine {
      // 屏幕共享 best-effort 停止（挂断/离会/dispose 都经此 → 不残留共享）。
      if screenSharing { _ = engine.stopScreenShare() }
      _ = engine.publishLocalVideoStream(false)
      _ = engine.enableLocalVideo(false)
      _ = engine.stopPreview()
      _ = engine.setLocalViewConfig(nil, for: .camera)
      for uid in remoteVideoViews.keys {
        _ = engine.setRemoteViewConfig(nil, uid: uid, for: .camera)
      }
      for uid in remoteScreenVideoViews.keys {
        _ = engine.setRemoteViewConfig(nil, uid: uid, for: .screen)
      }
    }
    screenSharing = false
    screenSourceTypes.removeAll()
    localVideoView = nil
    remoteVideoViews.removeAll()
    remoteScreenVideoViews.removeAll()
  }

  // MARK: - Method dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      if engine == nil {
        engine = DingRtcEngine.sharedInstance(self, extras: nil)
        rtcLog("initialize engine created")
      } else {
        rtcLog("initialize engine reused")
      }
      result(nil)

    case "joinChannel":
      guard let engine = engine else {
        result(FlutterError(code: "not_initialized", message: "call initialize first", details: nil))
        return
      }
      guard let args = call.arguments as? [String: Any],
        let appId = args["appId"] as? String,
        let channelId = args["channelId"] as? String,
        let userId = args["userId"] as? String,
        let token = args["token"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "joinChannel missing appId/channelId/userId/token", details: nil))
        return
      }
      let auth = DingRtcAuthInfo()
      auth.appId = appId
      auth.channelId = channelId
      auth.userId = userId
      auth.token = token
      if let gslb = args["gslbServer"] as? String, !gslb.isEmpty {
        auth.gslbServer = gslb
      }
      wantsVideo = (args["video"] as? Bool) ?? false
      // 音频媒体: 发布本地音频 + 订阅远端音频 + 开麦（audio/video 共用）。
      let audioPublishRc = engine.publishLocalAudioStream(true)
      let audioSubscribeRc = engine.subscribeAllRemoteAudioStreams(true)
      let audioCaptureRc = engine.startAudioCapture()
      rtcLog("joinChannel request channel=\(channelId) user=\(userId) video=\(wantsVideo) has_gslb=\(auth.gslbServer != nil) audio_publish_rc=\(audioPublishRc) audio_subscribe_rc=\(audioSubscribeRc) audio_capture_rc=\(audioCaptureRc)")
      // 视频媒体 (单一责任): native 在 join 时开本地摄像头 + 发布本地视频 + 订阅远端视频。
      // 聚合三步 rc：任一非 0 → 并入同步返回码，让 Dart joinChannel 按 rc!=0 失败 → 走 join-fail 清理。
      // 三个表达式作为函数实参均会求值（无短路），故 enable/publish/subscribe 必全部执行。
      var videoSetupRc: Int32 = 0
      if wantsVideo {
        videoSetupRc = firstNonZeroRc(
          engine.enableLocalVideo(true),
          engine.publishLocalVideoStream(true),
          engine.subscribeAllRemoteVideoStreams(true))
      }
      // DingRTC 要求 RTM / Agent delegate 在入会前设置；否则语音/TTS 可能正常，
      // 但 onTranscriptionMessage 等 RTM 智能体事件会偶发丢失。
      setupRtmAgent(engine: engine)
      let joinRc = engine.joinChannel(auth, name: nil) { [weak self] errCode, _, _, _ in
        if errCode != 0 {
          self?.rtcLog("joinChannel async result failed channel=\(channelId) user=\(userId) err=\(errCode)")
          self?.emit(["type": "error", "code": Int(errCode), "message": "joinChannel onResult failed"])
        }
      }
      // 若视频平台视图已先于 join 挂载，则此刻补绑定 (caller 早挂 local / 复用)；rc 检查见 applyView。
      if wantsVideo {
        applyLocalView()
        for uid in remoteVideoViews.keys { applyRemoteView(uid: uid) }
      }
      DingRtcBridge.currentChannelId = channelId
      DingRtcBridge.currentUserId = userId
      if joinRc != 0 {
        teardownRtmAgent()
      }
      // 同步返回首个非 0 rc：join 本身失败优先，其次视频建立失败（Dart 据此 join-fail 清理）。
      let resultRc = firstNonZeroRc(joinRc, videoSetupRc)
      rtcLog("joinChannel return channel=\(channelId) user=\(userId) result_rc=\(resultRc) join_rc=\(joinRc) video_setup_rc=\(videoSetupRc)")
      result(NSNumber(value: resultRc))

    case "setMicrophoneMuted":
      let muted = (call.arguments as? [String: Any])?["muted"] as? Bool ?? false
      let rc = engine?.muteLocalAudio(muted) ?? -1
      rtcLog("setMicrophoneMuted muted=\(muted) rc=\(rc)")
      result(nil)

    case "setCameraEnabled":
      // 摄像头开关按钮 (通话中)：enableLocalVideo + publishLocalVideoStream (已确认 API，返回 int rc)。
      // 返回 rc 给 Dart 做 rc!=0 判失败 (与 join/leave 一致)；取两次调用首个非 0，否则 0。
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      let rc1 = engine?.enableLocalVideo(enabled) ?? -1
      let rc2 = engine?.publishLocalVideoStream(enabled) ?? -1
      if enabled {
        if localVideoView != nil { _ = engine?.startPreview() } // 有本地视图才预览
      } else {
        _ = engine?.stopPreview()
      }
      let rc = rc1 != 0 ? rc1 : rc2
      rtcLog("setCameraEnabled enabled=\(enabled) rc=\(rc) enable_rc=\(rc1) publish_rc=\(rc2)")
      result(NSNumber(value: rc))

    case "leaveChannel":
      // 离会前防御性释放视频采集/预览（video 通话遗留），再离会释放音频。
      DingRtcBridge.currentChannelId = nil
      DingRtcBridge.currentUserId = nil
      teardownRtmAgent()
      releaseVideoCapture()
      let rc = engine?.leaveChannel() ?? -1
      rtcLog("leaveChannel rc=\(rc)")
      result(NSNumber(value: rc))

    case "listDevices":
      // 麦克风/扬声器/摄像头设备列表（仅 Mac，复用同一 engine）。**不打印 token**。
      guard let engine = engine else { result([]); return }
      let kind = (call.arguments as? [String: Any])?["kind"] as? String ?? ""
      let (devices, currentId) = deviceList(engine, kind: kind)
      let arr: [[String: Any]] = devices.map { d in
        [
          "id": d.deviceID ?? "",
          "name": d.deviceName ?? (d.deviceID ?? ""),
          "kind": kind,
          "is_current": (d.deviceID != nil && d.deviceID == currentId),
        ]
      }
      result(arr)

    case "selectDevice":
      // 切换设备 + **回读校验**：当前设备 == 目标 → rc 0；否则 rc -1（setter 无返回码，回读判定）。
      guard let engine = engine,
        let args = call.arguments as? [String: Any],
        let kind = args["kind"] as? String,
        let deviceId = args["deviceId"] as? String
      else {
        result(NSNumber(value: -1))
        return
      }
      result(NSNumber(value: selectDevice(engine, kind: kind, deviceId: deviceId) ? 0 : -1))

    case "listScreenShareSources":
      // 屏幕/窗口源（仅 Mac）。无屏幕录制权限 → 空列表（不弹权限，仅 start 时才弹）。**不打印 token**。
      guard let engine = engine, CGPreflightScreenCaptureAccess() else {
        result([])
        return
      }
      result(listScreenSources(engine))

    case "startScreenShare":
      guard let engine = engine else {
        result(NSNumber(value: -1))
        return
      }
      // 权限缺失 → 触发系统授权弹窗 + 明确错误（不静默失败、不假成功）。
      if !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        result(FlutterError(code: "screen_permission_denied",
                            message: "需要屏幕录制权限，请在系统设置中授权后重试", details: nil))
        return
      }
      let sourceId = (call.arguments as? [String: Any])?["sourceId"] as? String
      result(NSNumber(value: startScreenShareInternal(engine, sourceId: sourceId)))

    case "stopScreenShare":
      let rc = engine?.stopScreenShare() ?? 0
      screenSharing = false
      result(NSNumber(value: rc))

    case "dispose":
      if engine != nil {
        teardownRtmAgent()
        releaseVideoCapture()
        DingRtcEngine.destroy()
        engine = nil
      }
      wantsVideo = false
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 设备枚举 / 选择（DingRTC macOS：麦克风/扬声器/摄像头三类均支持）

  private func deviceList(_ engine: DingRtcEngine, kind: String) -> ([DingRtcDeviceInfo], String?) {
    switch kind {
    case "microphone":
      return (engine.getAudioCaptures() ?? [], engine.getCurrentAudioCaptureID())
    case "speaker":
      return (engine.getAudioRenderers() ?? [], engine.getCurrentAudioRendererID())
    case "camera":
      return (engine.getCameraList() ?? [], engine.getCurrentCameraID())
    default:
      return ([], nil)
    }
  }

  /// 切换设备后回读当前设备校验（setter 返回 void，无 rc 可借）。匹配 → true。
  private func selectDevice(_ engine: DingRtcEngine, kind: String, deviceId: String) -> Bool {
    switch kind {
    case "microphone":
      engine.setCurrentAudioCaptureWithID(deviceId)
      return engine.getCurrentAudioCaptureID() == deviceId
    case "speaker":
      engine.setCurrentAudioRendererWithID(deviceId)
      return engine.getCurrentAudioRendererID() == deviceId
    case "camera":
      engine.setCurrentCameraWithID(deviceId)
      return engine.getCurrentCameraID() == deviceId
    default:
      return false
    }
  }

  // MARK: - F16 RTM 智能体控制层 (Phase 0: 观测/握手)

  /// joinChannel 前挂 RTM delegate。服务端 StartAgent 起 agent 时隐式建 RTM session,
  /// 客户端收 onSessionCreate → joinSession → onAgentUserReady 拿 agentId。Phase 0 只观测+日志。
  private func setupRtmAgent(engine: DingRtcEngine) {
    let rtm = engine.getRtmClient()
    rtm.setDelegate(self)
    rtmClient = rtm
    let agentClient = rtm.getRtmAgentClient()
    agentClient.setDelegate(self)
    rtmAgentClient = agentClient
    rtcLog("rtm setup ok before join (waiting onSessionCreate)")
  }

  private func teardownRtmAgent() {
    if let sid = agentSessionId {
      _ = rtmClient?.leaveSession(sid)
    }
    rtmClient?.setDelegate(nil)
    rtmAgentClient?.setDelegate(nil)
    rtmClient = nil
    rtmAgentClient = nil
    agentSessionId = nil
    agentUserId = nil
  }

  // MARK: - 屏幕共享（DingRTC macOS：getScreenShareSourceInfoWithType / startScreenShareWith{Desktop,Window}Id / stopScreenShare）

  private func listScreenSources(_ engine: DingRtcEngine) -> [[String: Any]] {
    var out: [[String: Any]] = []
    screenSourceTypes.removeAll()
    let kinds: [(DingRtcScreenShareType, String)] = [(.desktop, "screen"), (.window, "window")]
    for (type, kindName) in kinds {
      let sources = engine.getScreenShareSourceInfo(with: type) ?? []
      for s in sources {
        screenSourceTypes[s.sourceId] = type
        out.append(["id": s.sourceId, "name": s.sourceName, "kind": kindName])
      }
    }
    return out
  }

  /// sourceId 为 nil → 取首个桌面（整个屏幕）；否则按枚举时记录的类型选桌面/窗口接口。
  private func startScreenShareInternal(_ engine: DingRtcEngine, sourceId: String?) -> Int32 {
    let config = DingRtcScreenShareConfig()
    var rc: Int32 = -1
    if let sid = sourceId, !sid.isEmpty {
      let type = screenSourceTypes[sid] ?? .desktop
      if type == .window {
        rc = engine.startScreenShare(withWindowId: sid, config: config)
      } else {
        rc = engine.startScreenShare(withDesktopId: sid, config: config)
      }
    } else {
      let desktops = engine.getScreenShareSourceInfo(with: .desktop) ?? []
      guard let first = desktops.first else { return -1 }
      rc = engine.startScreenShare(withDesktopId: first.sourceId, config: config)
    }
    if rc == 0 { screenSharing = true }
    return rc
  }

  // MARK: - DingRtcEngineDelegate

  func onJoinChannelResult(_ result: Int32, channel: String, userId: String, elapsed: Int32) {
    rtcLog("onJoinChannelResult result=\(result) channel=\(channel) user=\(userId) elapsed_ms=\(elapsed)")
    if result == 0 {
      emit(["type": "joined", "channelId": channel, "userId": userId])
    } else {
      emit(["type": "error", "code": Int(result), "message": "onJoinChannelResult failed"])
    }
  }

  func onLeaveChannelResult(_ result: Int32, stats: DingRtcStats) {
    rtcLog("onLeaveChannelResult result=\(result)")
    emit(["type": "left"])
  }

  // ObjC selector onRemoteUserOnLineNotify:elapsed: → Swift onRemoteUser(onLineNotify:elapsed:)。
  func onRemoteUser(onLineNotify uid: String, elapsed: Int32) {
    rtcLog("remote user joined uid=\(uid) elapsed_ms=\(elapsed)")
    emit(["type": "remoteUserJoined", "userId": uid])
  }

  func onRemoteUserOffLineNotify(_ uid: String, offlineReason reason: DingRtcUserOfflineReason) {
    rtcLog("remote user left uid=\(uid) reason=\(reason.rawValue)")
    emit(["type": "remoteUserLeft", "userId": uid])
  }

  func onRemoteTrackAvailableNotify(_ uid: String, audioTrack: DingRtcAudioTrack, videoTrack: DingRtcVideoTrack) {
    let screenAvailable = (videoTrack.rawValue & DingRtcVideoTrack.screen.rawValue) != 0
    let cameraAvailable = (videoTrack.rawValue & DingRtcVideoTrack.camera.rawValue) != 0
    rtcLog("remote track available uid=\(uid) audio_track=\(audioTrack.rawValue) video_track=\(videoTrack.rawValue) screen_available=\(screenAvailable) camera_available=\(cameraAvailable)")
    emit(["type": "screenShare", "scope": "remote", "active": screenAvailable, "userId": uid])
    // 语音通话中对方开摄像头时，通知 Dart 挂载远端视频画面（与 Android 对齐）。
    emit(["type": "remoteVideo", "userId": uid, "enabled": cameraAvailable])
  }

  // 本端网络质量变化（uid=="" 为 self）。综合上下行：任一中断→2；全未知→3；否则取较差(good0/poor1)。
  func onNetworkQualityChanged(_ uid: String, up upQuality: DingRtcNetworkQuality,
                              downNetworkQuality downQuality: DingRtcNetworkQuality) {
    guard uid.isEmpty else { return }
    let levels = [upQuality.rawValue, downQuality.rawValue]
    let level: Int
    if levels.contains(2) {
      level = 2
    } else if levels.allSatisfy({ $0 == 3 }) {
      level = 3
    } else {
      level = Int(levels.filter { $0 != 3 }.max() ?? 3)
    }
    rtcLog("network quality self up=\(upQuality.rawValue) down=\(downQuality.rawValue) level=\(level)")
    emit(["type": "networkQuality", "level": level])
  }

  // 本端屏幕共享推流状态：newState==3(Published)=共享中；其余=未共享（含异步失败/停止）。
  func onScreenSharePublishStateChanged(_ oldState: DingRtcPublishState,
                                        newState: DingRtcPublishState,
                                        elapseSinceLastState: Int,
                                        channel: String) {
    let active = newState.rawValue == 3 // DingRtcStatsPublished
    screenSharing = active
    rtcLog("screen share publish state old=\(oldState.rawValue) new=\(newState.rawValue) active=\(active) channel=\(channel)")
    emit(["type": "screenShare", "scope": "local", "active": active])
  }

  // 远端屏幕共享订阅状态：newState>=2(Subscribing/Subscribed)=对方在共享。
  func onScreenShareSubscribeStateChanged(_ uid: String,
                                          oldState: DingRtcSubscribeState,
                                          newState: DingRtcSubscribeState,
                                          elapseSinceLastState: Int,
                                          channel: String) {
    let active = newState.rawValue >= 2
    rtcLog("screen share subscribe state uid=\(uid) old=\(oldState.rawValue) new=\(newState.rawValue) active=\(active) channel=\(channel)")
    emit(["type": "screenShare", "scope": "remote", "active": active, "userId": uid])
  }

  func onOccurError(_ error: Int32, message: String) {
    emit(["type": "error", "code": Int(error), "message": message])
  }

  // F16 v0.7 分组讨论: join/leave/mix 都是异步 (rc=0 仅受理); 真实结果经这些回调。
  // 转发给会议窗口 (NotificationCenter), 由其在 join 成功后再 mix/switch (SDK 前提: 用户已在目标组)。
  func onAudioGroupJoinResult(_ result: Int32, errorMessage: String?, group: String, members: [DingRtcAudioGroupMemberInfo]) {
    rtcLog("audioGroup join result=\(result) group=\(group) err=\(errorMessage ?? "")")
    NotificationCenter.default.post(name: .easyoAudioGroupEvent, object: nil, userInfo: [
      "op": "join", "result": Int(result), "group": group,
    ])
  }

  func onAudioGroupLeaveResult(_ result: Int32, errorMessage: String?, group: String) {
    rtcLog("audioGroup leave result=\(result) group=\(group) err=\(errorMessage ?? "")")
    NotificationCenter.default.post(name: .easyoAudioGroupEvent, object: nil, userInfo: [
      "op": "leave", "result": Int(result), "group": group,
    ])
  }

  func onAudioGroupMixResult(_ result: Int32, reason: String?, group: String, mix: Bool) {
    rtcLog("audioGroup mix result=\(result) group=\(group) mix=\(mix) reason=\(reason ?? "")")
    NotificationCenter.default.post(name: .easyoAudioGroupEvent, object: nil, userInfo: [
      "op": "mix", "result": Int(result), "group": group,
    ])
  }
}

// F16 v0.7 会中讨论: 文档视图从顶部排列 (NSView 默认坐标系翻转)。
final class FlippedClipView: NSView {
  override var isFlipped: Bool { true }
}

// macOS 26 (Tahoe): NSButton 内部会按 cellSize(内容) 直接改写自身 frame, 绕过 Auto Layout —
// required 宽高约束 + intrinsic 全部钉在 38x32 仍 dump 出 38x42/41x42, 且无约束冲突日志。
// 因此除覆盖 intrinsic 外, 还要把 frame 尺寸写入口本身钉死, 谁来改都只落到 fixedSize。
final class FixedSizeButton: NSButton {
  var fixedSize = NSSize(width: 38, height: 32)
  override var intrinsicContentSize: NSSize { fixedSize }
  override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(fixedSize) }
}

// F16 v0.7 分组讨论事件 (DingRtcBridge → 会议窗口)。
extension Notification.Name {
  static let easyoAudioGroupEvent = Notification.Name("easyo.rtc.audioGroupEvent")
  static let easyoRtmSessionJoin = Notification.Name("easyo.rtc.rtmSessionJoin")
  static let easyoRtmChatMessage = Notification.Name("easyo.rtc.rtmChatMessage")
}

// MARK: - F16 RTM 客户端事件 (Phase 0: 观测/握手)
// 收 onSessionCreate → joinSession; 其余只日志 + emit 给 Flutter (Dart 暂忽略未知 type, 不影响)。
extension DingRtcBridge: DingRtmClientDelegate {
  func onRtmServerStateChanged(_ state: DingRtmServerState, error: Int32) {
    rtcLog("rtm server state=\(state.rawValue) error=\(error)")
  }

  func onSessionCreate(_ sessionId: String) {
    rtcLog("rtm onSessionCreate session=\(sessionId) → joinSession")
    agentSessionId = sessionId
    _ = rtmClient?.joinSession(sessionId)
  }

  func onJoinSessionResult(_ sessionId: String, result: Int32) {
    rtcLog("rtm onJoinSessionResult session=\(sessionId) result=\(result)")
    NotificationCenter.default.post(name: .easyoRtmSessionJoin, object: nil, userInfo: [
      "sessionId": sessionId, "result": Int(result),
    ])
  }

  func onMessage(_ sessionId: String, uid: String, broadcast: Bool, data: Data) {
    // 会中讨论消息 (RTM broadcast)。内容不打日志, 只打长度。
    rtcLog("rtm onMessage session=\(sessionId) uid=\(uid) broadcast=\(broadcast) bytes=\(data.count)")
    NotificationCenter.default.post(name: .easyoRtmChatMessage, object: nil, userInfo: [
      "sessionId": sessionId, "uid": uid, "data": data,
    ])
  }

  func onLeaveSessionResult(_ sessionId: String, result: Int32) {
    rtcLog("rtm onLeaveSessionResult session=\(sessionId) result=\(result)")
  }

  func onSessionClose(_ sessionId: String) {
    rtcLog("rtm onSessionClose session=\(sessionId)")
    if sessionId == agentSessionId { agentSessionId = nil; agentUserId = nil }
  }

  func onRemoved(fromSession sessionId: String, reason: Int32) {
    rtcLog("rtm onRemovedFromSession session=\(sessionId) reason=\(reason)")
    if sessionId == agentSessionId { agentSessionId = nil; agentUserId = nil }
  }
}

// MARK: - F16 RTM 智能体事件 (Phase 0: 观测; Phase 2/3 接 UI)
extension DingRtcBridge: DingRtmAgentClientDelegate {
  func onAgentUserReady(_ sessionId: String, agentId: String) {
    rtcLog("rtm onAgentUserReady session=\(sessionId) agent=\(agentId)")
    agentSessionId = sessionId
    agentUserId = agentId
    emit(["type": "agentReady", "sessionId": sessionId, "agentId": agentId])
  }

  func onAgentStateChanged(_ sessionId: String, agentId: String, state: DingAgentState) {
    // 1=Listening 2=Thinking 3=Responding。Phase 2 把它映射成"聆听中/思考中/回答中"。
    rtcLog("rtm onAgentStateChanged session=\(sessionId) agent=\(agentId) state=\(state.rawValue)")
    emit(["type": "agentState", "agentId": agentId, "state": Int(state.rawValue)])
  }

  func onTranscriptionMessage(_ sessionId: String, agentId: String, data: DingRtmAgentTranscriptionData) {
    // speakerType: 1=User 2=Agent。end=本轮是否结束 (碎片只在 end 才定稿)。
    // Phase 3 按 roundId 渲染气泡; reasoningText 做过程提示。Phase 0 只日志+emit, 不打文本内容长度以外信息到 NSLog。
    let speaker: String
    switch data.speakerType {
    case .user:
      speaker = "user"
    case .agent:
      speaker = "agent"
    @unknown default:
      rtcLog("rtm transcription ignored unknown speaker_type=\(data.speakerType) session=\(sessionId) round=\(data.roundId) end=\(data.end) text_chars=\(data.text.count) reasoning_chars=\(data.reasoningText.count)")
      return
    }
    rtcLog("rtm transcription session=\(sessionId) speaker=\(speaker) round=\(data.roundId) end=\(data.end) text_chars=\(data.text.count) reasoning_chars=\(data.reasoningText.count)")
    emit([
      "type": "agentTranscription",
      "speaker": speaker,
      "roundId": Int(data.roundId),
      "end": data.end,
      "text": data.text,
      "reasoning": data.reasoningText,
      // A1 排序键: 轮次开始时间(ms)。0/缺失时 Dart 退化为 firstSeenAt(设计 §3.2 fallback)。
      "beginTime": Int(clamping: data.beginTime),
    ])
  }
}

// MARK: - 视频画面 PlatformView 工厂

/// FlutterPlatformViewFactory: Dart 侧 AppKitView(viewType: "easyo/rtc/video_view") 创建时,
/// 返回一个 NSView 容器并交给 DingRtcBridge 绑定到 DingRTC 的本地/远端 canvas。
/// creationParams: { role: "local"|"remote", userId?: String, callUuid?: String }。
final class DingRtcVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var bridge: DingRtcBridge?

  init(bridge: DingRtcBridge) {
    self.bridge = bridge
    super.init()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let params = args as? [String: Any] ?? [:]
    let role = (params["role"] as? String) ?? "remote"
    let userId = params["userId"] as? String
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    bridge?.bindVideoView(container, role: role, userId: userId)
    return container
  }

  func createArgsCodec() -> (NSObjectProtocol & FlutterMessageCodec)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

// MARK: - F16 被叫来电「屏幕级」原生浮窗（NSPanel）

/// 屏幕右下角独立来电浮窗（不局限于 app 窗口内），可拖动，含拒接/接听。
/// 只做 UI 唤醒：按钮点击通过 EventChannel 回传 Dart，真正状态推进仍走 HTTP /calls/*。
/// MethodChannel "easyo/rtc/incoming_panel"：show(callUuid/peerName/mediaKind)→Bool、hide。
/// EventChannel "easyo/rtc/incoming_panel/events"：{action:"accept"|"reject"|"close"}。
final class RtcIncomingPanelBridge: NSObject, FlutterStreamHandler {
  private static var instance: RtcIncomingPanelBridge?
  private var eventSink: FlutterEventSink?
  private var panel: NSPanel?

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = RtcIncomingPanelBridge()
    let methods = FlutterMethodChannel(name: "easyo/rtc/incoming_panel", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in bridge.handle(call, result: result) }
    let events = FlutterEventChannel(name: "easyo/rtc/incoming_panel/events", binaryMessenger: messenger)
    events.setStreamHandler(bridge)
    instance = bridge
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ action: String) {
    DispatchQueue.main.async { [weak self] in self?.eventSink?(["action": action]) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "show":
      let args = call.arguments as? [String: Any] ?? [:]
      let peerName = (args["peerName"] as? String) ?? "同事"
      let peerAvatarUrl = (args["peerAvatarUrl"] as? String) ?? ""
      let mediaKind = (args["mediaKind"] as? String) ?? "audio"
      // **不读 token**；仅 UI 字段。
      showPanel(peerName: peerName, mediaKind: mediaKind, peerAvatarUrl: peerAvatarUrl)
      result(true) // 已显示原生浮窗 → Dart 隐藏 app 内来电卡
    case "hide":
      hidePanel()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 面板构建

  private func showPanel(peerName: String, mediaKind: String, peerAvatarUrl: String) {
    hidePanel()
    let size = NSSize(width: 320, height: 116)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true // 拖背景即可移动
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isOpaque = false

    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.white.cgColor
    root.layer?.cornerRadius = 12
    root.layer?.masksToBounds = true
    panel.contentView = root

    let isVideo = mediaKind == "video"
    // 头像圆
    let avatar = NSView(frame: NSRect(x: 16, y: size.height - 16 - 40, width: 40, height: 40))
    avatar.wantsLayer = true
    avatar.layer?.backgroundColor = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 0.16).cgColor
    avatar.layer?.cornerRadius = 20
    let initial = makeLabel(String(peerName.prefix(1)), size: 16, color: NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1))
    initial.alignment = .center
    initial.sizeToFit()
    let ih = initial.frame.height
    initial.frame = NSRect(x: 0, y: (40 - ih) / 2, width: 40, height: ih)
    avatar.addSubview(initial)
    root.addSubview(avatar)
    if let url = URL(string: peerAvatarUrl), !peerAvatarUrl.isEmpty {
      DispatchQueue.global(qos: .userInitiated).async {
        guard let image = NSImage(contentsOf: url) else { return }
        DispatchQueue.main.async {
          guard self.panel === panel else { return }
          initial.isHidden = true
          let imageView = NSImageView(frame: avatar.bounds)
          imageView.image = image
          imageView.imageScaling = .scaleAxesIndependently
          imageView.wantsLayer = true
          imageView.layer?.cornerRadius = 20
          imageView.layer?.masksToBounds = true
          avatar.addSubview(imageView, positioned: .below, relativeTo: initial)
        }
      }
    }

    // 标题 + 副标题
    let title = makeLabel(peerName, size: 14, color: NSColor(white: 0.11, alpha: 1), bold: true)
    title.frame = NSRect(x: 68, y: size.height - 18 - 18, width: 160, height: 18)
    root.addSubview(title)
    let subtitle = makeLabel("邀请你进行\(isVideo ? "视频" : "语音")通话", size: 12, color: NSColor(white: 0.53, alpha: 1))
    subtitle.frame = NSRect(x: 68, y: size.height - 18 - 38, width: 236, height: 16)
    subtitle.lineBreakMode = .byTruncatingTail
    root.addSubview(subtitle)

    // 拒接（红）/ 接听（绿）：必须有白色电话/视频图标，避免只显示空圆。
    let reject = makeCircleButton(red: 1, green: 0.23, blue: 0.19,
                                  symbol: "phone.down.fill", fallback: "挂",
                                  action: #selector(onReject))
    reject.frame = NSRect(x: size.width - 16 - 40 - 12 - 40, y: 14, width: 40, height: 40)
    root.addSubview(reject)
    let accept = makeCircleButton(red: 0.20, green: 0.78, blue: 0.35,
                                  symbol: isVideo ? "video.fill" : "phone.fill",
                                  fallback: isVideo ? "视" : "接",
                                  action: #selector(onAccept))
    accept.frame = NSRect(x: size.width - 16 - 40, y: 14, width: 40, height: 40)
    root.addSubview(accept)

    // 屏幕右上角
    if let vf = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24))
    }
    panel.orderFrontRegardless()
    self.panel = panel
  }

  private func hidePanel() {
    panel?.orderOut(nil)
    panel = nil
  }

  @objc private func onAccept() {
    emit("accept")
    hidePanel()
  }
  @objc private func onReject() {
    emit("reject")
    hidePanel()
  }

  private func makeLabel(_ text: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    l.textColor = color
    l.backgroundColor = .clear
    l.isBordered = false
    l.isEditable = false
    return l
  }

  private func makeCircleButton(red: CGFloat, green: CGFloat, blue: CGFloat,
                                symbol: String, fallback: String,
                                action: Selector) -> NSButton {
    let b = NSButton(frame: .zero)
    b.title = ""
    b.isBordered = false
    b.wantsLayer = true
    b.layer?.backgroundColor = NSColor(red: red, green: green, blue: blue, alpha: 1).cgColor
    b.layer?.cornerRadius = 20
    if let img = symbolImage(symbol) {
      b.image = img
      b.imagePosition = .imageOnly
      b.contentTintColor = .white
    } else {
      b.title = fallback
      b.font = NSFont.boldSystemFont(ofSize: 14)
      b.contentTintColor = .white
    }
    b.target = self
    b.action = action
    return b
  }

  private func symbolImage(_ name: String) -> NSImage? {
    if #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
    return nil
  }
}

// MARK: - F16 统一会议模型 · macOS 独立会议窗口（NSWindow，飞书/企微质感）
//
// 接通(active)后 audio/video 都进入同一个会议窗口（audio = cameraOff 的会议，
// video = cameraOn 的会议）。窗口是同一 app 内的独立 NSWindow（可拖/可缩放/可最小化、
// 非置顶、非独立进程），其内 NSView 通过 `DingRtcBridge.bindMeetingVideoView` 绑定到
// **同一** DingRtcEngine 承载真实视频，**不新建第二套 RTC engine**。
// 仅做 UI：按钮经 EventChannel 回传给 RtcCallController；状态推进仍走 HTTP /calls/*，1001 不改 state。
// 关闭窗口 = 回传 hangUp（由 controller→后端→reset→hide 收尾，避免双重关闭）。
//
// 视觉结构（v0.3.33 polish）：
//   ┌───────────────────────────────────────────────┐
//   │ header 50：会议信息 · 时长 · 信号 │ 布局 复位 │  白底 + 底分隔线
//   ├──────────────────────────────┬────────────────┤
//   │ stage 白底                     │ side panel 320 │  gallery 16:9 左右分屏 / speaker 16:9 远端大+本地 PiP
//   │  [local tile]  [remote tile]   │  参会人列表     │  panel 开时 stage 收窄
//   ├──────────────────────────────┴────────────────┤
//   │ toolbar 56：飞书式单行 controls；mic/camera = 主按钮 + 设备下拉 split-button │  白底 + 顶分隔线
//   └───────────────────────────────────────────────┘
// 真实可用：mic / camera / 参会人(开关侧栏) / 布局(gallery↔speaker) / 挂断。
// disabled 预留态（灰显 + tooltip「暂未支持」、不假成功）：共享 / 录制 / 字幕 / 邀请 / 更多。

final class RtcMeetingWindowBridge: NSObject, FlutterStreamHandler, NSWindowDelegate {
  private static var instance: RtcMeetingWindowBridge?
  private var eventSink: FlutterEventSink?

  /// 一个视频块（容器 + 视频 surface + 头像覆盖层 + 左下角姓名条）。
  private struct TileRefs {
    let container: NSView
    let surface: NSView
    let avatar: NSView
    let circle: NSView
    let initialLabel: NSTextField
    let captionLabel: NSTextField
    let nameLabel: NSTextField
  }

  /// 参会人侧栏一行（头像 + 姓名 + 状态）。
  private struct RowRefs {
    let container: NSView
    let circle: NSView
    let initialLabel: NSTextField
    let name: NSTextField
    let status: NSTextField
  }

  /// 工具栏一项（飞书式 icon 按钮 + 底部小字标签）。
  private struct BarItem {
    let container: NSView
    let button: NSButton
    let label: NSTextField
  }

  private static let toolbarButtonSize = NSSize(width: 38, height: 32)
  private static let toolbarSplitButtonSize = NSSize(width: 64, height: 32)
  private static let toolbarChevronSize = NSSize(width: 25, height: 32)
  private static let toolbarSlotWidth: CGFloat = 46
  private static let toolbarSplitSlotWidth: CGFloat = 68
  private static let toolbarButtonCornerRadius: CGFloat = 5

  private var window: NSWindow?
  // header
  private var titleLabel: NSTextField?
  private var durationLabel: NSTextField?
  private var networkLabel: NSTextField?
  private var headerInviteBtn: NSButton?
  // stage / tiles
  private var bodyRow: NSView?
  private var stage: NSView?
  private var localTile: TileRefs?
  private var remoteTile: TileRefs?
  // 多人画廊 (>=2 个远端时启用，含本地共 3 格起)：本地 + 每个远端 (含呼叫中的) 各一个
  // TileRefs，key = uid (已入会) / "calling:N" (呼叫中) / "local"。localTile/remoteTile
  // 那套固定两格布局在 <2 个远端时继续用，互不影响。
  private var multiGridContainer: NSView?
  private var multiGridTiles: [String: TileRefs] = [:]
  private var multiGridVideoBindings: [String: String] = [:]
  private var multiGridAvatarLoadedURLs: [String: String] = [:]
  // side panel
  private var sidePanel: NSView?
  private var selfRowName: NSTextField?
  private var selfRowInitial: NSTextField?
  private var selfRowStatus: NSTextField?
  private var peerRowName: NSTextField?
  private var peerRowInitial: NSTextField?
  private var peerRowStatus: NSTextField?
  private var participantsStack: NSStackView?
  // toolbar
  private var micBtn: NSButton?
  private var camBtn: NSButton?
  private var micLabel: NSTextField?
  private var camLabel: NSTextField?
  private var participantsLabel: NSTextField?
  private var inviteItemContainer: NSView?
  // 设备 picker（由 applyState 从 Dart 状态写入，菜单按需读取）
  private var micDevices: [[String: Any]] = []
  private var speakerDevices: [[String: Any]] = []
  private var cameraDevices: [[String: Any]] = []
  private var speakerSupported = true
  // 屏幕共享
  private var shareBtn: NSButton?
  private var shareLabel: NSTextField?
  private var shareBanner: NSTextField?
  private var screenSharingNow = false
  private var screenShareSources: [[String: Any]] = []
  private var shareControlPanel: NSPanel?
  private var shareControlDurationLabel: NSTextField?
  private var shareControlMicBtn: NSButton?
  private var shareControlCamBtn: NSButton?
  private var shareControlStopBtn: NSButton?
  // F16 v0.7 会议能力扩展（feature §7.6 / TDD v0.3.27）：状态必须真实，失败回滚不假成功。
  private var captionBtn: NSButton?
  private var moreBtn: NSButton?
  private var denoiseOn = false
  private var subtitleOn = false
  private var currentAudioGroup: String? // nil = 大厅
  private var pendingAudioGroup: String? // join 已受理、等 onAudioGroupJoinResult
  private var audioGroupObserver: NSObjectProtocol?
  private var subtitleWaitTimer: Timer? // 开启后迟迟无数据 → 诚实回滚 (服务端任务未开通)
  private var subtitleBar: NSTextField? // stage 底部轻量字幕条（不改布局）
  private var whiteboardWindow: NSWindow?
  private var whiteboardObj: DingRtcEngineWhiteboard?
  // 会中讨论 (RTM session broadcast; 会中临时, 不持久化到 IM — defer)。
  private var discussionPanel: NSView?
  private var discussionStack: NSStackView?
  private var discussionScroll: NSScrollView?
  private var discussionInput: NSTextField?
  private var discussionOpen = false
  private var chatSessionId: String?
  private var chatSessionJoined = false
  private var chatSessionJoining = false
  private var pendingReaction: String?
  private var rtmChatObserver: NSObjectProtocol?
  private var rtmJoinObserver: NSObjectProtocol?
  private var reactionMenuBtn: NSButton?
  private var discussionOpenConstraints: [NSLayoutConstraint] = []
  private var discussionEmpty: NSTextField?
  private var discussionTitle: NSTextField?
  private var discussionAvatar: NSTextField?
  private var discussionSendBtn: NSButton?
  private var headerView: NSView?
  private var toolbarView: NSView?
  private var chromeFullConstraints: [NSLayoutConstraint] = [] // header/toolbar 贴满右缘 (讨论关)
  private var lastPeerName = ""          // D1: applyState 直存对端名 (peerRowName 控件可能未填充)
  private var lastSelfName = "我"         // 自己显示名 (气泡头像首字用)
  private var lastChatMsgDate: Date?     // D4: 时间分割 (≥5min 插 HH:mm)
  // layout state + constraint groups
  private var currentLayout = "gallery"
  private var panelOpen = false
  private var layoutInitialized = false
  private var panelInitialized = false
  private var galleryConstraints: [NSLayoutConstraint] = []
  private var speakerConstraints: [NSLayoutConstraint] = []
  private var panelOpenConstraints: [NSLayoutConstraint] = []
  private var panelClosedConstraints: [NSLayoutConstraint] = []

  private var startDate: Date?
  private var timer: Timer?
  private var boundRemoteBindingKey: String?

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = RtcMeetingWindowBridge()
    let methods = FlutterMethodChannel(name: "easyo/rtc/meeting", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in bridge.handle(call, result: result) }
    let events = FlutterEventChannel(name: "easyo/rtc/meeting/events", binaryMessenger: messenger)
    events.setStreamHandler(bridge)
    instance = bridge
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ action: String) {
    DispatchQueue.main.async { [weak self] in self?.eventSink?(["action": action]) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "show":
      let args = call.arguments as? [String: Any] ?? [:]
      showWindow(args)
      result(true) // 已显示原生会议窗口 → Dart 主窗口只显示轻量状态条
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      applyState(args)
      result(nil)
    case "hide":
      hideWindow()
      result(nil)
    case "bringToFront":
      // 回到会议窗口：恢复（取消最小化）+ 前置聚焦。
      window?.deminiaturize(nil)
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 窗口构建

  private func showWindow(_ s: [String: Any]) {
    if window == nil { buildWindow() }
    applyState(s)
    if let window = window { positionTrafficLights(in: window) }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let window = window {
      DispatchQueue.main.async { [weak self, weak window] in
        guard let window = window else { return }
        self?.positionTrafficLights(in: window)
      }
    }
  }

  private func buildWindow() {
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    w.title = "视频通话"
    w.minSize = NSSize(width: 860, height: 540)
    w.isReleasedWhenClosed = false // 复用窗口；hide 仅 orderOut
    // 内容铺到标题栏（飞书质感）：隐藏系统标题文字，红绿灯浮在自定义 header 左上。
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.styleMask.insert(.fullSizeContentView)
    w.delegate = self
    w.center()

    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.white.cgColor
    w.contentView = content

    let header = buildHeader()
    let body = buildBody()
    let toolbar = buildToolbar()
    bodyRow = body
    headerView = header
    toolbarView = toolbar
    // body 先加（在底层），header/toolbar 后加（覆盖在上、含分隔线）。
    [body, header, toolbar].forEach { content.addSubview($0) }

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: content.topAnchor),
      header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      header.heightAnchor.constraint(equalToConstant: 42),

      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 56),

      body.topAnchor.constraint(equalTo: header.bottomAnchor),
      body.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
      body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
    ])
    // P1: header/toolbar 右缘可切换 — 讨论开时收到面板左缘 (面板通顶通底, 飞书式整列)。
    chromeFullConstraints = [
      header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
    ]
    NSLayoutConstraint.activate(chromeFullConstraints)

    self.window = w
    positionTrafficLights(in: w)
    DispatchQueue.main.async { [weak self, weak w] in
      guard let window = w else { return }
      self?.positionTrafficLights(in: window)
    }
    applyLayout(currentLayout)
    applyPanel(panelOpen)
  }

  private func positionTrafficLights(in window: NSWindow) {
    let buttons: [NSButton] = [
      window.standardWindowButton(.closeButton),
      window.standardWindowButton(.miniaturizeButton),
      window.standardWindowButton(.zoomButton),
    ].compactMap { $0 }
    guard !buttons.isEmpty else { return }
    let startX: CGFloat = 18
    let gap: CGFloat = 28
    let centerYFromTop: CGFloat = 21
    for (idx, button) in buttons.enumerated() {
      guard let superview = button.superview else { continue }
      var frame = button.frame
      let boundsHeight = superview.bounds.height
      let desiredY = boundsHeight - centerYFromTop - frame.height / 2
      let minY: CGFloat = 2
      let maxY = max(minY, boundsHeight - frame.height - 2)
      frame.origin.x = startX + CGFloat(idx) * gap
      frame.origin.y = min(max(desiredY, minY), maxY)
      button.setFrameOrigin(frame.origin)
      button.isHidden = false
      button.alphaValue = 1
    }
  }

  // MARK: 视觉常量

  private var kStageBg: NSColor { NSColor.white }
  private var kTileBg: NSColor { NSColor(red: 0.944, green: 0.948, blue: 0.954, alpha: 1) }
  private var kSeparator: NSColor { NSColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1) }
  private var kBrand: NSColor { NSColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1) } // #2563EB
  private var kInk: NSColor { NSColor(white: 0.11, alpha: 1) }
  private var kSub: NSColor { NSColor(white: 0.5, alpha: 1) }
  private var kHangup: NSColor { NSColor(red: 0.91, green: 0.27, blue: 0.24, alpha: 1) }
  private var kControlBg: NSColor { NSColor(red: 0.944, green: 0.952, blue: 0.968, alpha: 1) }
  private var kDisabledControlBg: NSColor { NSColor(red: 0.972, green: 0.976, blue: 0.982, alpha: 1) }

  // MARK: 顶栏

  private func buildHeader() -> NSView {
    let header = NSView()
    header.wantsLayer = true
    header.layer?.backgroundColor = NSColor.white.cgColor
    header.translatesAutoresizingMaskIntoConstraints = false

    let sep = makeSeparator()
    sep.layer?.backgroundColor = NSColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 0.72).cgColor
    header.addSubview(sep)

    let pill = NSView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(pill)

    // 左：会议窗口 header，贴合设计稿的标题/分享/时长/网络状态结构。
    let title = makeLabel("会议信息", size: 12, color: NSColor(white: 0.16, alpha: 1))
    let share = makeHeaderGlyph(symbol: "square.and.arrow.up", fallback: "↗", action: #selector(onInvite))
    share.toolTip = "邀请参会人"
    let dur = makeLabel("00:00", size: 12, color: NSColor(white: 0.24, alpha: 1))
    let net = makeLabel("▮▮▮", size: 12, color: NSColor(red: 0.17, green: 0.70, blue: 0.38, alpha: 1), bold: true)
    let divider = makeVerticalDivider()
    [title, share, dur, net, divider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
    titleLabel = title
    headerInviteBtn = share
    durationLabel = dur
    networkLabel = net

    // 右：布局切换 · 回到默认位置
    let layoutBtn = makeHeaderCapsuleButton(symbol: "rectangle.split.2x1", fallback: "布局", action: #selector(onLayout))
    layoutBtn.toolTip = "切换布局（画廊 / 演讲者）"
    let restoreBtn = makeHeaderCapsuleButton(symbol: "arrow.counterclockwise", fallback: "复位", action: #selector(onRestore))
    restoreBtn.toolTip = "回到默认位置"

    let leftInset: CGFloat = 86 // 让开左上角红绿灯，并对齐飞书式标题起点。
    [title, share, divider, dur, net, layoutBtn, restoreBtn].forEach { pill.addSubview($0) }
    NSLayoutConstraint.activate([
      sep.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      sep.bottomAnchor.constraint(equalTo: header.bottomAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1),

      pill.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      pill.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      pill.topAnchor.constraint(equalTo: header.topAnchor),
      pill.bottomAnchor.constraint(equalTo: header.bottomAnchor),

      title.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: leftInset),
      title.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      share.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 14),
      share.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      divider.leadingAnchor.constraint(equalTo: share.trailingAnchor, constant: 14),
      divider.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      dur.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 14),
      dur.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      net.leadingAnchor.constraint(equalTo: dur.trailingAnchor, constant: 16),
      net.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

      restoreBtn.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
      restoreBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      layoutBtn.trailingAnchor.constraint(equalTo: restoreBtn.leadingAnchor, constant: -18),
      layoutBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
    ])
    return header
  }

  // MARK: 主体（stage + 参会人侧栏）

  private func buildBody() -> NSView {
    let body = NSView()
    body.translatesAutoresizingMaskIntoConstraints = false

    let stageView = NSView()
    stageView.wantsLayer = true
    stageView.layer?.backgroundColor = kStageBg.cgColor
    stageView.translatesAutoresizingMaskIntoConstraints = false
    stage = stageView
    body.addSubview(stageView)

    let local = makeTile(initial: "我", caption: "摄像头已关", name: "我")
    let remote = makeTile(initial: "·", caption: "等待对方加入", name: "对方")
    localTile = local
    remoteTile = remote
    // remote 先加、local 后加 → speaker 模式 local PiP 浮在 remote 之上。
    stageView.addSubview(remote.container)
    stageView.addSubview(local.container)

    // 多人画廊容器：>=2 个远端 (含呼叫中) 时启用，跟固定两格布局叠在同一个
    // stageView 里，靠 isHidden 互斥切换，见 applyState。
    let grid = NSView()
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.isHidden = true
    stageView.addSubview(grid)
    multiGridContainer = grid

    // 屏幕共享 presenter 横幅（本端/远端共享时显示，居中顶部；不伪造共享画面内容）。
    let banner = makeLabel("", size: 12, color: .white)
    banner.alignment = .center
    banner.wantsLayer = true
    banner.layer?.backgroundColor = kBrand.cgColor
    banner.layer?.cornerRadius = 6
    banner.isHidden = true
    banner.translatesAutoresizingMaskIntoConstraints = false
    stageView.addSubview(banner)
    shareBanner = banner

    // F16 v0.7 实时字幕条：stage 底部单条轻量 overlay（默认隐藏，不改 stage 布局）。
    let subBar = makeLabel("", size: 13, color: .white)
    subBar.wantsLayer = true
    subBar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
    subBar.layer?.cornerRadius = 6
    subBar.alignment = .center
    subBar.lineBreakMode = .byTruncatingHead
    subBar.isHidden = true
    subBar.translatesAutoresizingMaskIntoConstraints = false
    stageView.addSubview(subBar)
    subtitleBar = subBar

    let panel = buildSidePanel()
    sidePanel = panel
    body.addSubview(panel)

    NSLayoutConstraint.activate([
      banner.topAnchor.constraint(equalTo: stageView.topAnchor, constant: 14),
      banner.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
      banner.heightAnchor.constraint(equalToConstant: 26),
      banner.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

      subBar.bottomAnchor.constraint(equalTo: stageView.bottomAnchor, constant: -12),
      subBar.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
      subBar.heightAnchor.constraint(equalToConstant: 24),
      subBar.widthAnchor.constraint(lessThanOrEqualTo: stageView.widthAnchor, multiplier: 0.8),
      subBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

      stageView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      stageView.topAnchor.constraint(equalTo: body.topAnchor),
      stageView.bottomAnchor.constraint(equalTo: body.bottomAnchor),

      grid.leadingAnchor.constraint(equalTo: stageView.leadingAnchor, constant: 16),
      grid.trailingAnchor.constraint(equalTo: stageView.trailingAnchor, constant: -16),
      grid.topAnchor.constraint(equalTo: stageView.topAnchor, constant: 16),
      grid.bottomAnchor.constraint(equalTo: stageView.bottomAnchor, constant: -16),

      panel.topAnchor.constraint(equalTo: body.topAnchor),
      panel.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      panel.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      panel.widthAnchor.constraint(equalToConstant: 320),
    ])

    // 侧栏开关：closed → stage 占满；open → stage 收到 panel 左缘。
    panelClosedConstraints = [stageView.trailingAnchor.constraint(equalTo: body.trailingAnchor)]
    panelOpenConstraints = [stageView.trailingAnchor.constraint(equalTo: panel.leadingAnchor)]

    let l = local.container, r = remote.container
    let pad: CGFloat = 20
    let localAspect = l.heightAnchor.constraint(equalTo: l.widthAnchor, multiplier: 9.0 / 16.0)
    localAspect.priority = NSLayoutConstraint.Priority(999)
    galleryConstraints = [
      l.leadingAnchor.constraint(equalTo: stageView.leadingAnchor, constant: pad),
      l.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),
      l.topAnchor.constraint(greaterThanOrEqualTo: stageView.topAnchor, constant: pad),
      l.bottomAnchor.constraint(lessThanOrEqualTo: stageView.bottomAnchor, constant: -pad),
      localAspect,
      r.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 20),
      r.widthAnchor.constraint(equalTo: l.widthAnchor),
      r.heightAnchor.constraint(equalTo: l.heightAnchor),
      r.trailingAnchor.constraint(equalTo: stageView.trailingAnchor, constant: -pad),
      r.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),
      r.topAnchor.constraint(greaterThanOrEqualTo: stageView.topAnchor, constant: pad),
      r.bottomAnchor.constraint(lessThanOrEqualTo: stageView.bottomAnchor, constant: -pad),
    ]
    let speakerAspect = r.heightAnchor.constraint(equalTo: r.widthAnchor, multiplier: 9.0 / 16.0)
    speakerAspect.priority = NSLayoutConstraint.Priority(999)
    let speakerWidthFill = r.widthAnchor.constraint(equalTo: stageView.widthAnchor, constant: -48)
    speakerWidthFill.priority = .defaultHigh
    speakerConstraints = [
      r.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
      r.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),
      r.leadingAnchor.constraint(greaterThanOrEqualTo: stageView.leadingAnchor, constant: 24),
      r.trailingAnchor.constraint(lessThanOrEqualTo: stageView.trailingAnchor, constant: -24),
      r.topAnchor.constraint(greaterThanOrEqualTo: stageView.topAnchor, constant: 24),
      r.bottomAnchor.constraint(lessThanOrEqualTo: stageView.bottomAnchor, constant: -24),
      speakerWidthFill,
      speakerAspect,
      l.widthAnchor.constraint(equalToConstant: 180),
      l.heightAnchor.constraint(equalToConstant: 120),
      l.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -16),
      l.bottomAnchor.constraint(equalTo: r.bottomAnchor, constant: -16),
    ]
    return body
  }

  /// 视频块：container(#1F1F1F 圆角 8) + 视频 surface(绑定句柄) + 头像覆盖层 + 左下角姓名条。
  private func makeTile(initial: String, caption: String, name: String) -> TileRefs {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = kTileBg.cgColor
    container.layer?.cornerRadius = 4
    container.layer?.masksToBounds = true
    container.translatesAutoresizingMaskIntoConstraints = false

    let surface = NSView()
    surface.wantsLayer = true
    surface.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(surface)

    // 头像覆盖层（无画面时显示）：圆形首字母 + 下方说明。
    let avatar = NSView()
    avatar.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(avatar)
    let circle = NSView()
    circle.wantsLayer = true
    circle.layer?.backgroundColor = NSColor(red: 0.43, green: 0.70, blue: 0.12, alpha: 1).cgColor
    circle.layer?.cornerRadius = 28
    circle.translatesAutoresizingMaskIntoConstraints = false
    let initialLabel = makeLabel(initial, size: 21, color: .white, bold: true)
    initialLabel.alignment = .center
    initialLabel.translatesAutoresizingMaskIntoConstraints = false
    circle.addSubview(initialLabel)
    avatar.addSubview(circle)
    let captionLabel = makeLabel(caption, size: 12, color: NSColor(white: 0.70, alpha: 1))
    captionLabel.alignment = .center
    captionLabel.isHidden = true
    captionLabel.translatesAutoresizingMaskIntoConstraints = false
    avatar.addSubview(captionLabel)

    // 左下角姓名条（半透明黑底 + 白字）。
    let nameTag = NSView()
    nameTag.wantsLayer = true
    nameTag.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
    nameTag.layer?.cornerRadius = 2
    nameTag.translatesAutoresizingMaskIntoConstraints = false
    let nameLabel = makeLabel(name, size: 10, color: NSColor(white: 0.20, alpha: 1))
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameTag.addSubview(nameLabel)
    container.addSubview(nameTag)

    NSLayoutConstraint.activate([
      surface.topAnchor.constraint(equalTo: container.topAnchor),
      surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),

      avatar.topAnchor.constraint(equalTo: container.topAnchor),
      avatar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      avatar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      avatar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      circle.widthAnchor.constraint(equalToConstant: 56),
      circle.heightAnchor.constraint(equalToConstant: 56),
      circle.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
      circle.centerYAnchor.constraint(equalTo: avatar.centerYAnchor, constant: -6),
      initialLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
      initialLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
      captionLabel.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 10),
      captionLabel.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),

      nameTag.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
      nameTag.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
      nameLabel.topAnchor.constraint(equalTo: nameTag.topAnchor, constant: 2),
      nameLabel.bottomAnchor.constraint(equalTo: nameTag.bottomAnchor, constant: -2),
      nameLabel.leadingAnchor.constraint(equalTo: nameTag.leadingAnchor, constant: 4),
      nameLabel.trailingAnchor.constraint(equalTo: nameTag.trailingAnchor, constant: -4),
    ])
    return TileRefs(container: container, surface: surface, avatar: avatar, circle: circle,
                    initialLabel: initialLabel, captionLabel: captionLabel, nameLabel: nameLabel)
  }

  // MARK: 参会人侧栏

  private func buildSidePanel() -> NSView {
    let panel = NSView()
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor(red: 0.985, green: 0.988, blue: 0.992, alpha: 1).cgColor
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.isHidden = true

    let sep = NSView()
    sep.wantsLayer = true
    sep.layer?.backgroundColor = kSeparator.cgColor
    sep.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(sep)

    let title = makeLabel("参会人", size: 14, color: kInk, bold: true)
    title.translatesAutoresizingMaskIntoConstraints = false
    let closeBtn = makeHeaderButton(symbol: "xmark", fallback: "关闭", action: #selector(onToggleParticipants))
    closeBtn.toolTip = "收起参会人"

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    participantsStack = stack

    [title, closeBtn, stack].forEach { panel.addSubview($0) }
    NSLayoutConstraint.activate([
      sep.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
      sep.topAnchor.constraint(equalTo: panel.topAnchor),
      sep.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
      sep.widthAnchor.constraint(equalToConstant: 1),

      title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
      title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
      closeBtn.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
      closeBtn.centerYAnchor.constraint(equalTo: title.centerYAnchor),

      stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
    ])
    return panel
  }

  private func makeParticipantRow(initial: String) -> RowRefs {
    let row = NSView()
    row.wantsLayer = true
    row.layer?.cornerRadius = 8
    row.layer?.backgroundColor = NSColor.clear.cgColor
    row.translatesAutoresizingMaskIntoConstraints = false
    row.heightAnchor.constraint(equalToConstant: 54).isActive = true
    let circle = NSView()
    circle.wantsLayer = true
    circle.layer?.backgroundColor = NSColor(red: 0.43, green: 0.70, blue: 0.12, alpha: 1).cgColor
    circle.layer?.cornerRadius = 18
    circle.translatesAutoresizingMaskIntoConstraints = false
    let ini = makeLabel(initial, size: 14, color: .white, bold: true)
    ini.alignment = .center
    ini.translatesAutoresizingMaskIntoConstraints = false
    circle.addSubview(ini)
    let name = makeLabel("", size: 13, color: NSColor(white: 0.13, alpha: 1))
    name.translatesAutoresizingMaskIntoConstraints = false
    let status = makeLabel("", size: 11, color: NSColor(white: 0.55, alpha: 1))
    status.translatesAutoresizingMaskIntoConstraints = false
    [circle, name, status].forEach { row.addSubview($0) }
    NSLayoutConstraint.activate([
      circle.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
      circle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      circle.widthAnchor.constraint(equalToConstant: 36),
      circle.heightAnchor.constraint(equalToConstant: 36),
      ini.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
      ini.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
      name.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 10),
      name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      status.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
      status.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    return RowRefs(container: row, circle: circle, initialLabel: ini, name: name, status: status)
  }

  /// 给参会人侧栏一行加载真实头像；行每次 renderParticipantRows 都会重建，不做跨帧
  /// memoization（与 updateTileAvatar 不同）。url 为空/加载失败 → 保留首字母占位。
  private func updateRowAvatar(_ row: RowRefs, url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let nsUrl = URL(string: trimmed) else { return }
    let circle = row.circle
    let initialLabel = row.initialLabel
    DispatchQueue.global(qos: .userInitiated).async {
      guard let image = NSImage(contentsOf: nsUrl) else { return }
      DispatchQueue.main.async {
        guard circle.superview != nil else { return } // 行已被下一次渲染移除
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 18
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(imageView, positioned: .below, relativeTo: initialLabel)
        NSLayoutConstraint.activate([
          imageView.widthAnchor.constraint(equalToConstant: 36),
          imageView.heightAnchor.constraint(equalToConstant: 36),
          imageView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
          imageView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        initialLabel.isHidden = true
      }
    }
  }

  private func renderParticipantRows(selfName: String, selfAvatarUrl: String, muted: Bool,
                                      joined: [(name: String, avatar: String)],
                                      calling: [(name: String, avatar: String)]) {
    guard let stack = participantsStack else { return }
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    func addRow(name: String, avatar: String, status: String, initial: String? = nil) {
      let row = makeParticipantRow(initial: initial ?? String(name.prefix(1)))
      row.name.stringValue = name
      row.status.stringValue = status
      stack.addArrangedSubview(row.container)
      row.container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      updateRowAvatar(row, url: avatar)
    }

    addRow(name: selfName, avatar: selfAvatarUrl, status: muted ? "已静音" : "麦克风开", initial: "我")
    for p in joined {
      addRow(name: p.name, avatar: p.avatar, status: "在线")
    }
    for p in calling {
      addRow(name: p.name, avatar: p.avatar, status: "呼叫中...")
    }
  }

  // MARK: 底部工具栏

  private func buildToolbar() -> NSView {
    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = NSColor.white.cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    let sep = makeSeparator()
    toolbar.addSubview(sep)

    let bar = NSStackView()
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 7
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: Self.toolbarButtonSize.height).isActive = true

    // 麦克风/摄像头：主按钮 toggle，右下角 chevron 打开设备菜单。扬声器：整键打开菜单。
    let mic = makeBarItem(symbol: "mic.fill", fallback: "麦", label: "麦克风", tooltip: nil,
                          action: #selector(onMic), chevronAction: #selector(onMicMenu))
    let cam = makeBarItem(symbol: "video.fill", fallback: "像", label: "摄像头", tooltip: nil,
                          action: #selector(onCam), chevronAction: #selector(onCamMenu))
    let speaker = makeBarItem(symbol: "speaker.wave.2.fill", fallback: "音", label: "扬声器",
                              tooltip: nil, action: #selector(onSpeakerMenu))
    let share = makeBarItem(symbol: "rectangle.on.rectangle", fallback: "享", label: "共享",
                            tooltip: nil, action: #selector(onShare))
    let record = makeBarItem(symbol: "record.circle", fallback: "录", label: "录制", tooltip: "录制 · 暂未支持", action: nil)
    let participants = makeBarItem(symbol: "person.2.fill", fallback: "人", label: "参会人", tooltip: nil, action: #selector(onToggleParticipants))
    let invite = makeBarItem(symbol: "person.badge.plus", fallback: "邀", label: "邀请", tooltip: nil, action: #selector(onInvite))
    let more = makeBarItem(symbol: "ellipsis", fallback: "…", label: "更多", tooltip: nil, action: #selector(onMoreMenu))
    let hang = makeBarItem(symbol: "phone.down.fill", fallback: "挂", label: "结束", tooltip: nil, action: #selector(onHangup), danger: true)

    micBtn = mic.button
    camBtn = cam.button
    micLabel = mic.label
    camLabel = cam.label
    participantsLabel = participants.label
    inviteItemContainer = invite.container
    shareBtn = share.button
    shareLabel = share.label
    moreBtn = more.button

    [mic, cam, speaker, share, record, participants, invite, more].forEach {
      bar.addArrangedSubview($0.container)
    }
    // 与红色结束键拉开间距。
    let gap = NSView()
    gap.translatesAutoresizingMaskIntoConstraints = false
    gap.widthAnchor.constraint(equalToConstant: 24).isActive = true
    bar.addArrangedSubview(gap)
    bar.addArrangedSubview(hang.container)

    toolbar.addSubview(bar)

    // F16 v0.7.3 左下角（飞书式·轻量原色）: 👍 / OK(橙) / 😊(选择器) + 讨论。
    // 反应键不用工具键灰底方块 — 无框、emoji 原色、紧凑（A1/A2）。
    let thumb = makeReactionButton(text: "👍", tooltip: "点赞", action: #selector(onReactionThumb))
    let okBtn = makeReactionButton(text: "OK", tooltip: "OK", action: #selector(onReactionOK), isOK: true)
    let emoji = makeReactionButton(text: "☺", tooltip: "表情回应", action: #selector(onReactionMenu), symbol: "face.smiling")
    // let discuss = makeReactionButton(text: "", tooltip: "会中讨论", action: #selector(onToggleDiscussion), symbol: "text.bubble")
    captionBtn = emoji
    reactionMenuBtn = emoji
    let leftBar = NSStackView(views: [thumb, okBtn, emoji]) // , discuss
    leftBar.orientation = .horizontal
    leftBar.alignment = .centerY
    leftBar.spacing = 6
    leftBar.translatesAutoresizingMaskIntoConstraints = false
    leftBar.heightAnchor.constraint(equalToConstant: Self.toolbarButtonSize.height).isActive = true
    toolbar.addSubview(leftBar)

    NSLayoutConstraint.activate([
      sep.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
      sep.topAnchor.constraint(equalTo: toolbar.topAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1),
      bar.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
      bar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      leftBar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
      leftBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
    ])
    return toolbar
  }

  /// 工具栏一项：飞书式小圆角 icon 按钮。action 为 nil → disabled 预留态（灰显、tooltip「暂未支持」、不假成功）。
  /// chevronAction != nil → 主按钮右侧紧邻设备菜单小箭头（真实，点开设备列表）。
  private func makeBarItem(symbol: String, fallback: String, label: String,
                           tooltip: String?, action: Selector?, danger: Bool = false,
                           chevronAction: Selector? = nil) -> BarItem {
    let b = FixedSizeButton()
    b.title = ""
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.wantsLayer = true
    // v0.7: 红色结束键与普通键尺寸**逐项一致** (仅配色不同), 工具栏所有按钮同宽同高。
    let buttonWidth = Self.toolbarButtonSize.width
    let buttonHeight = Self.toolbarButtonSize.height
    b.fixedSize = Self.toolbarButtonSize // 压住 macOS26 内容驱动 intrinsic
    _ = danger // 尺寸不再特殊化
    b.layer?.cornerRadius = Self.toolbarButtonCornerRadius
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
    b.heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true

    let lab = makeLabel(label, size: 10, color: NSColor(white: 0.34, alpha: 1))
    lab.alignment = .center
    lab.isHidden = true
    lab.translatesAutoresizingMaskIntoConstraints = false
    lab.lineBreakMode = .byTruncatingTail

    if danger {
      b.layer?.backgroundColor = kHangup.cgColor
      b.contentTintColor = .white
      setButtonGlyph(b, symbol: symbol, fallback: fallback, tint: .white)
    } else if action != nil {
      b.layer?.backgroundColor = kControlBg.cgColor
      b.contentTintColor = NSColor(white: 0.2, alpha: 1)
      setButtonGlyph(b, symbol: symbol, fallback: fallback, tint: NSColor(white: 0.2, alpha: 1))
    } else {
      b.layer?.backgroundColor = kDisabledControlBg.cgColor
      b.contentTintColor = NSColor(white: 0.62, alpha: 1)
      lab.textColor = NSColor(white: 0.68, alpha: 1)
      setButtonGlyph(b, symbol: symbol, fallback: fallback, tint: NSColor(white: 0.62, alpha: 1))
    }

    if let a = action {
      b.target = self
      b.action = a
      b.toolTip = tooltip ?? label
      b.setAccessibilityLabel(tooltip ?? label)
    } else {
      b.isEnabled = false
      b.alphaValue = 0.6
      b.toolTip = tooltip
      b.setAccessibilityLabel(tooltip)
    }

    let control = NSStackView()
    control.orientation = .horizontal
    control.alignment = .centerY
    control.spacing = 0
    control.wantsLayer = true
    control.translatesAutoresizingMaskIntoConstraints = false

    if let chev = chevronAction {
      control.layer?.backgroundColor = kControlBg.cgColor
      control.layer?.cornerRadius = Self.toolbarButtonCornerRadius
      control.layer?.masksToBounds = true
      b.layer?.backgroundColor = NSColor.clear.cgColor
      b.layer?.cornerRadius = 0
      let chevron = makeChevron(action: chev)
      control.addArrangedSubview(b)
      control.addArrangedSubview(makeVerticalDivider())
      control.addArrangedSubview(chevron)
      control.widthAnchor.constraint(equalToConstant: Self.toolbarSplitButtonSize.width).isActive = true
      control.heightAnchor.constraint(equalToConstant: Self.toolbarSplitButtonSize.height).isActive = true
    } else {
      control.addArrangedSubview(b)
      control.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
      control.heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true
    }

    let stack = NSStackView(views: [control])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.widthAnchor.constraint(equalToConstant: chevronAction == nil ? Self.toolbarSlotWidth : Self.toolbarSplitSlotWidth).isActive = true
    stack.heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true // 防御: 容器不随任何路径拉伸
    return BarItem(container: stack, button: b, label: lab)
  }

  /// 设备菜单小箭头。飞书/企微类会议工具里它是按钮的一部分，避免做成贴片感小胶囊。
  private func makeChevron(action: Selector) -> NSButton {
    let c = FixedSizeButton()
    c.fixedSize = Self.toolbarChevronSize
    c.title = ""
    c.isBordered = false
    c.bezelStyle = .regularSquare
    c.wantsLayer = true
    c.layer?.backgroundColor = NSColor.clear.cgColor
    c.layer?.cornerRadius = 0
    c.translatesAutoresizingMaskIntoConstraints = false
    c.widthAnchor.constraint(equalToConstant: Self.toolbarChevronSize.width).isActive = true
    c.heightAnchor.constraint(equalToConstant: Self.toolbarChevronSize.height).isActive = true
    if let img = symbolImage("chevron.down") {
      c.contentTintColor = NSColor(white: 0.44, alpha: 1)
      installCenteredImage(img, in: c, tint: NSColor(white: 0.44, alpha: 1), side: 14)
    } else {
      c.contentTintColor = NSColor(white: 0.44, alpha: 1)
      installCenteredText("⌄", in: c, font: NSFont.systemFont(ofSize: 9, weight: .medium),
                          color: NSColor(white: 0.44, alpha: 1))
    }
    c.target = self
    c.action = action
    c.toolTip = "选择设备"
    return c
  }

  private func makeVerticalDivider() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor(red: 0.82, green: 0.85, blue: 0.89, alpha: 1).cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: 1).isActive = true
    v.heightAnchor.constraint(equalToConstant: 16).isActive = true
    return v
  }

  /// 顶栏/侧栏小按钮。圆角浅底，对齐设计图右侧操作按钮。
  private func makeHeaderButton(symbol: String, fallback: String, action: Selector) -> NSButton {
    let b = NSButton()
    b.title = ""
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.wantsLayer = true
    b.layer?.backgroundColor = kControlBg.cgColor
    b.layer?.cornerRadius = 7
    b.translatesAutoresizingMaskIntoConstraints = false
    b.heightAnchor.constraint(equalToConstant: 34).isActive = true
    if let img = symbolImage(symbol) {
      b.image = img
      b.imagePosition = .imageOnly
      b.contentTintColor = NSColor(white: 0.25, alpha: 1)
      b.widthAnchor.constraint(equalToConstant: 44).isActive = true
    } else {
      b.title = fallback
      b.font = NSFont.systemFont(ofSize: 12)
      b.contentTintColor = NSColor(white: 0.25, alpha: 1)
      b.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }
    b.target = self
    b.action = action
    return b
  }

  /// 会议窗口 header 右侧轻量按钮：飞书式文本/图标，不做大描边方块。
  private func makeHeaderCapsuleButton(symbol: String, fallback: String, action: Selector) -> NSButton {
    let b = NSButton()
    b.title = fallback == "布局" ? "布局" : ""
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.wantsLayer = true
    b.layer?.backgroundColor = NSColor.clear.cgColor
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: fallback == "布局" ? 58 : 28).isActive = true
    b.heightAnchor.constraint(equalToConstant: 28).isActive = true
    if let img = symbolImage(symbol) {
      b.image = img
      b.imagePosition = fallback == "布局" ? .imageLeft : .imageOnly
      b.contentTintColor = NSColor(white: 0.14, alpha: 1)
    } else {
      b.title = fallback
      b.font = NSFont.systemFont(ofSize: 12)
      b.contentTintColor = NSColor(white: 0.14, alpha: 1)
    }
    b.font = NSFont.systemFont(ofSize: 12)
    b.target = self
    b.action = action
    return b
  }

  private func makeHeaderGlyph(symbol: String, fallback: String, action: Selector) -> NSButton {
    let b = NSButton()
    b.title = ""
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.wantsLayer = true
    b.layer?.backgroundColor = NSColor.clear.cgColor
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: 22).isActive = true
    b.heightAnchor.constraint(equalToConstant: 26).isActive = true
    if let img = symbolImage(symbol) {
      b.image = img
      b.imagePosition = .imageOnly
      b.contentTintColor = NSColor(white: 0.35, alpha: 1)
    } else {
      b.title = fallback
      b.font = NSFont.systemFont(ofSize: 12)
      b.contentTintColor = NSColor(white: 0.35, alpha: 1)
    }
    b.target = self
    b.action = action
    return b
  }

  private func makeSeparator() -> NSView {
    let s = NSView()
    s.wantsLayer = true
    s.layer?.backgroundColor = kSeparator.cgColor
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
  }

  // MARK: 布局 / 侧栏切换（状态驱动；按钮只 emit，由 controller 回 update 再渲染）

  private func applyLayout(_ layout: String) {
    if layoutInitialized && layout == currentLayout { return }
    layoutInitialized = true
    currentLayout = layout
    NSLayoutConstraint.deactivate(galleryConstraints + speakerConstraints)
    NSLayoutConstraint.activate(layout == "speaker" ? speakerConstraints : galleryConstraints)
    localTile?.container.layer?.cornerRadius = layout == "speaker" ? 6 : 8
  }

  private func applyPanel(_ open: Bool) {
    if open && discussionOpen { setDiscussionOpen(false) } // 参会人/讨论侧栏互斥（飞书同款）
    if panelInitialized && open == panelOpen { return }
    panelInitialized = true
    panelOpen = open
    sidePanel?.isHidden = !open
    applyStageTrailing()
  }

  /// stage/header/toolbar 右缘随讨论态切换：讨论开 → 全部收到面板左缘（面板通顶整列）；
  /// 否则参会人侧栏 > 占满。约束统一在此切换（带轻量动画）。
  private func applyStageTrailing() {
    NSLayoutConstraint.deactivate(
      panelClosedConstraints + panelOpenConstraints + discussionOpenConstraints + chromeFullConstraints)
    if discussionOpen && !discussionOpenConstraints.isEmpty {
      NSLayoutConstraint.activate(discussionOpenConstraints)
    } else {
      NSLayoutConstraint.activate(chromeFullConstraints)
      NSLayoutConstraint.activate(panelOpen ? panelOpenConstraints : panelClosedConstraints)
    }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      ctx.allowsImplicitAnimation = true
      self.window?.contentView?.layoutSubtreeIfNeeded()
    }
  }

  // MARK: 头像加载

  private var localAvatarLoadedURL: String = ""
  private var remoteAvatarLoadedURL: String = ""

  /// 给 tile 的圆形头像槽位加载真实图片；[isLocal] 只是用来区分两个 tile 各自的
  /// "已加载哪个 URL" 记忆，避免 applyState 高频重复调用时重复下载/重复插入图层。
  /// url 为空或加载失败 → 保留首字母占位，不留半成品。
  private func updateTileAvatar(_ tile: TileRefs?, url: String, isLocal: Bool) {
    guard let tile = tile else { return }
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let loadedURL = isLocal ? localAvatarLoadedURL : remoteAvatarLoadedURL
    if trimmed == loadedURL { return }
    if isLocal { localAvatarLoadedURL = trimmed } else { remoteAvatarLoadedURL = trimmed }

    tile.circle.subviews.forEach { if $0 is NSImageView { $0.removeFromSuperview() } }
    tile.initialLabel.isHidden = false
    guard !trimmed.isEmpty, let nsUrl = URL(string: trimmed) else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let image = NSImage(contentsOf: nsUrl) else { return }
      DispatchQueue.main.async {
        guard let self = self else { return }
        let currentLoaded = isLocal ? self.localAvatarLoadedURL : self.remoteAvatarLoadedURL
        guard currentLoaded == trimmed else { return } // 状态已变（换人/挂断），丢弃过期结果
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 28
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.circle.addSubview(imageView, positioned: .below, relativeTo: tile.initialLabel)
        NSLayoutConstraint.activate([
          imageView.widthAnchor.constraint(equalToConstant: 56),
          imageView.heightAnchor.constraint(equalToConstant: 56),
          imageView.centerXAnchor.constraint(equalTo: tile.circle.centerXAnchor),
          imageView.centerYAnchor.constraint(equalTo: tile.circle.centerYAnchor),
        ])
        tile.initialLabel.isHidden = true
      }
    }
  }

  /// 同 updateTileAvatar，但按任意字符串 id 记忆 (多人画廊每格一个 id，不再只有
  /// local/remote 两个固定槽位)。
  private func updateGridTileAvatar(_ tile: TileRefs, id: String, url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if multiGridAvatarLoadedURLs[id] == trimmed { return }
    multiGridAvatarLoadedURLs[id] = trimmed

    tile.circle.subviews.forEach { if $0 is NSImageView { $0.removeFromSuperview() } }
    tile.initialLabel.isHidden = false
    guard !trimmed.isEmpty, let nsUrl = URL(string: trimmed) else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let image = NSImage(contentsOf: nsUrl) else { return }
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.multiGridAvatarLoadedURLs[id] == trimmed else { return }
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 28
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.circle.addSubview(imageView, positioned: .below, relativeTo: tile.initialLabel)
        NSLayoutConstraint.activate([
          imageView.widthAnchor.constraint(equalToConstant: 56),
          imageView.heightAnchor.constraint(equalToConstant: 56),
          imageView.centerXAnchor.constraint(equalTo: tile.circle.centerXAnchor),
          imageView.centerYAnchor.constraint(equalTo: tile.circle.centerYAnchor),
        ])
        tile.initialLabel.isHidden = true
      }
    }
  }

  /// 多人画廊一格的数据：id 是 uid (已入会) / "calling:N" (呼叫中) / "local"。
  private struct GridEntry {
    let id: String
    let name: String
    let avatarUrl: String
    let isLocal: Bool
    let remoteUserId: String? // 有真实视频轨时才非空 (已入会且开摄像头/共享)
    let hasVideo: Bool
    let caption: String
  }

  /// 按 entries 重建多人画廊：≤2 列并排、3-4 格 2 列、更多 3 列 (跟 Flutter 端
  /// _MeetingGalleryGrid 同样的分栏规则)。tile 尽量复用 (按 id)，整个网格容器每次
  /// 全量重排——人数变化不频繁，简单可靠优先于极致性能。
  private func applyMultiGrid(_ entries: [GridEntry]) {
    guard let grid = multiGridContainer else { return }
    let neededIds = Set(entries.map { $0.id })
    for (id, tile) in multiGridTiles where !neededIds.contains(id) {
      tile.container.removeFromSuperview()
      multiGridTiles.removeValue(forKey: id)
      multiGridVideoBindings.removeValue(forKey: id)
      multiGridAvatarLoadedURLs.removeValue(forKey: id)
    }
    grid.subviews.forEach { $0.removeFromSuperview() }
    guard !entries.isEmpty else { return }

    let columns = entries.count <= 2 ? entries.count : (entries.count <= 4 ? 2 : 3)
    let rows = Int(ceil(Double(entries.count) / Double(columns)))
    let spacing: CGFloat = 12

    let rowStack = NSStackView()
    rowStack.orientation = .vertical
    rowStack.spacing = spacing
    rowStack.distribution = .fillEqually
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    grid.addSubview(rowStack)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
      rowStack.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
      rowStack.topAnchor.constraint(equalTo: grid.topAnchor),
      rowStack.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
    ])

    for r in 0..<rows {
      let colStack = NSStackView()
      colStack.orientation = .horizontal
      colStack.spacing = spacing
      colStack.distribution = .fillEqually
      colStack.translatesAutoresizingMaskIntoConstraints = false
      rowStack.addArrangedSubview(colStack)
      for c in 0..<columns {
        let idx = r * columns + c
        guard idx < entries.count else {
          let filler = NSView()
          filler.translatesAutoresizingMaskIntoConstraints = false
          colStack.addArrangedSubview(filler)
          continue
        }
        let entry = entries[idx]
        let tile = multiGridTiles[entry.id]
          ?? makeTile(initial: String(entry.name.prefix(1)), caption: entry.caption, name: entry.name)
        multiGridTiles[entry.id] = tile
        tile.nameLabel.stringValue = entry.name
        tile.initialLabel.stringValue = entry.name.isEmpty ? "·" : String(entry.name.prefix(1))
        tile.captionLabel.stringValue = entry.caption
        tile.captionLabel.isHidden = entry.caption.isEmpty || entry.hasVideo
        updateGridTileAvatar(tile, id: entry.id, url: entry.hasVideo ? "" : entry.avatarUrl)
        if entry.hasVideo {
          tile.avatar.isHidden = true
          let bindKey = entry.isLocal ? "local" : "camera:\(entry.remoteUserId ?? "")"
          if multiGridVideoBindings[entry.id] != bindKey {
            DingRtcBridge.bindMeetingVideoView(
              tile.surface,
              role: entry.isLocal ? "local" : "remote",
              userId: entry.isLocal ? nil : entry.remoteUserId)
            multiGridVideoBindings[entry.id] = bindKey
          }
        } else {
          tile.avatar.isHidden = false
          multiGridVideoBindings.removeValue(forKey: entry.id)
        }
        colStack.addArrangedSubview(tile.container)
      }
    }
  }

  // MARK: 状态应用

  private func applyState(_ s: [String: Any]) {
    let peer = (s["peerName"] as? String) ?? "对方"
    lastPeerName = peer
    lastSelfName = (s["selfDisplayName"] as? String) ?? "我"
    if discussionOpen { refreshDiscussionHeader() }
    let selfName = (s["selfDisplayName"] as? String) ?? "我"
    let isVideo = (s["mediaKind"] as? String) == "video"
    let muted = (s["muted"] as? Bool) ?? false
    let cameraOn = (s["cameraOn"] as? Bool) ?? false
    let remoteUid = (s["remoteUserId"] as? String) ?? ""
    let remoteIds = (s["remoteUserIds"] as? [String]) ?? []
    // 远端开了摄像头的成员（语音通话中对方中途开摄像头 → 也要挂远端视频，而非死 gate 在 isVideo）。
    let remoteCameraOnIds = (s["remoteCameraOnUserIds"] as? [String]) ?? []
    let remoteCameraOn = !remoteUid.isEmpty && remoteCameraOnIds.contains(remoteUid)
    let joinedNames = (s["joinedParticipantNames"] as? [String]) ?? []
    let joinedAvatars = (s["joinedParticipantAvatars"] as? [String]) ?? []
    let callingNames = (s["callingParticipantNames"] as? [String]) ?? []
    let callingAvatars = (s["callingParticipantAvatars"] as? [String]) ?? []
    let selfAvatarUrl = (s["selfAvatarUrl"] as? String) ?? ""
    let peerAvatarUrl = (s["peerAvatarUrl"] as? String) ?? ""
    let remoteScreenUid = (s["remoteScreenUserId"] as? String) ?? ""
    let elapsed = (s["elapsedSeconds"] as? Int) ?? 0
    let layout = (s["layout"] as? String) ?? "gallery"
    let panelOpenState = (s["participantsPanelOpen"] as? Bool) ?? false
    let canInviteParticipants = (s["canInviteParticipants"] as? Bool) ?? false
    let remoteSharing = (s["remoteScreenSharing"] as? Bool) ?? false
    func avatarAt(_ arr: [String], _ i: Int) -> String { i < arr.count ? arr[i] : "" }
    // 多人画廊：本地 + 已入会/呼叫中的远端总数 >= 2 (即总人数 >= 3) 时启用真正的
    // 网格，每人一格；屏幕共享时固定用旧的两格 (共享者内容需要独占大画面，网格里
    // 塞不下一个"占大部分空间"的 presenter block，先不处理这个组合场景)。
    let useMultiGrid = (remoteIds.count + callingNames.count) >= 2 && !remoteSharing
    localTile?.container.isHidden = useMultiGrid
    remoteTile?.container.isHidden = useMultiGrid
    multiGridContainer?.isHidden = !useMultiGrid

    // 标题：本地或初始媒介有视频即“视频通话”（audio→video 升级后本地有画面）。
    let isVideoTitle = isVideo || cameraOn
    titleLabel?.stringValue = "会议信息"
    headerInviteBtn?.isHidden = !canInviteParticipants
    inviteItemContainer?.isHidden = !canInviteParticipants
    window?.title = isVideoTitle ? "视频通话" : "语音通话"

    if startDate == nil {
      startDate = Date(timeIntervalSinceNow: -Double(elapsed))
      startTimer()
    }

    setButtonGlyph(micBtn, symbol: muted ? "mic.slash.fill" : "mic.fill",
                   fallback: muted ? "哑" : "麦", tint: NSColor(white: 0.2, alpha: 1))
    setButtonGlyph(camBtn, symbol: cameraOn ? "video.fill" : "video.slash.fill",
                   fallback: cameraOn ? "像" : "关", tint: NSColor(white: 0.2, alpha: 1))
    micLabel?.stringValue = muted ? "已静音" : "麦克风"
    camLabel?.stringValue = cameraOn ? "摄像头" : "已关闭"

    var displayPeer = peer
    var displayPeerAvatar = peerAvatarUrl
    if useMultiGrid {
      // 多人画廊：本地 + 每个远端 (已入会用真实 uid 视频轨，呼叫中用头像占位) 各一格，
      // 数据源跟侧栏/旧两格逻辑一致 (joinedNames/joinedAvatars/callingNames/callingAvatars)，
      // 保证三处显示互相一致。
      var entries: [GridEntry] = [
        GridEntry(id: "local", name: selfName, avatarUrl: selfAvatarUrl, isLocal: true,
                   remoteUserId: nil, hasVideo: cameraOn, caption: "摄像头已关"),
      ]
      for (i, uid) in remoteIds.enumerated() {
        let name = i < joinedNames.count && !joinedNames[i].isEmpty ? joinedNames[i] : "成员 \(i + 1)"
        let hasVideo = isVideo || remoteCameraOnIds.contains(uid)
        entries.append(GridEntry(id: uid, name: name, avatarUrl: avatarAt(joinedAvatars, i),
                                   isLocal: false, remoteUserId: uid, hasVideo: hasVideo, caption: name))
      }
      for i in 0..<callingNames.count {
        let name = callingNames[i].isEmpty ? "成员 \(remoteIds.count + i + 1)" : callingNames[i]
        entries.append(GridEntry(id: "calling:\(i)", name: name, avatarUrl: avatarAt(callingAvatars, i),
                                   isLocal: false, remoteUserId: nil, hasVideo: false, caption: "呼叫中..."))
      }
      applyMultiGrid(entries)
    } else {
      // 本地块：开摄像头才承载视频；否则头像预留态（不伪造画面）。
      localTile?.nameLabel.stringValue = selfName
      localTile?.initialLabel.stringValue = String(selfName.prefix(1))
      localTile?.captionLabel.stringValue = "摄像头已关"
      updateTileAvatar(localTile, url: selfAvatarUrl, isLocal: true)
      if cameraOn, let surface = localTile?.surface {
        localTile?.avatar.isHidden = true
        DingRtcBridge.bindMeetingVideoView(surface, role: "local", userId: nil)
      } else {
        localTile?.avatar.isHidden = false
      }

      // 远端块：远端共享优先显示 screen track；否则 video 通话显示摄像头，audio/未加入显示头像。
      // joined/callingAvatars 里数字员工等身份查不到时是空串而非数组为空，.first 拿到 "" 不是 nil，
      // 必须显式判空才能落到 peerAvatarUrl 兜底 (agent 1v1 通话唯一的头像来源)。
      // 名字同理不能只用静态的 peer——peer 是发起/收到这通通话那一刻定下的固定文案
      // (1v1 语义)，remoteUid 实际绑定的是"当前唯一显示"的那个人；群通话里谁先入会
      // 占了这个画面块跟 peer 指向的人不一定是同一个 (round 数轮排查：主画面块显示
      // "刘明"、侧栏正确显示"刘先生"就是这个不一致导致的)。优先用 joinedNames/
      // callingNames 里跟 remoteUid 真正对应的那个人名，查不到才退回 peer。
      let joinedFirstAvatar = joinedAvatars.first.flatMap { $0.isEmpty ? nil : $0 }
      let callingFirstAvatar = callingAvatars.first.flatMap { $0.isEmpty ? nil : $0 }
      let joinedFirstName = joinedNames.first.flatMap { $0.isEmpty ? nil : $0 }
      let callingFirstName = callingNames.first.flatMap { $0.isEmpty ? nil : $0 }
      displayPeer = !remoteUid.isEmpty ? (joinedFirstName ?? peer) : (callingFirstName ?? peer)
      displayPeerAvatar = !remoteUid.isEmpty
        ? (joinedFirstAvatar ?? peerAvatarUrl)
        : (callingFirstAvatar ?? peerAvatarUrl)
      remoteTile?.nameLabel.stringValue = displayPeer
      // remotePresent 控制"真人视频轨"相关状态 (摄像头绑定/字幕等)，仍然只认
      // 已入会/屏幕共享；但头像/首字母只要知道是谁 (已入会或呼叫中) 就该显示，
      // 不能卡死在"必须已入会"——之前呼叫中头像一直是空绿点就是这个问题。
      let remotePresent = !remoteUid.isEmpty || !remoteScreenUid.isEmpty
      let remoteKnown = remotePresent || callingFirstName != nil
      remoteTile?.initialLabel.stringValue = remoteKnown ? String(displayPeer.prefix(1)) : "·"
      updateTileAvatar(remoteTile, url: remoteKnown ? displayPeerAvatar : "", isLocal: false)
      if remoteSharing, !remoteScreenUid.isEmpty, let surface = remoteTile?.surface {
        remoteTile?.avatar.isHidden = true
        remoteTile?.nameLabel.stringValue = "\(peer) · 屏幕共享"
        let key = "screen:\(remoteScreenUid)"
        if key != boundRemoteBindingKey {
          DingRtcBridge.bindMeetingVideoView(surface, role: "remoteScreen", userId: remoteScreenUid)
          boundRemoteBindingKey = key
        }
      } else if (isVideo || remoteCameraOn), !remoteUid.isEmpty, let surface = remoteTile?.surface {
        remoteTile?.avatar.isHidden = true
        let key = "camera:\(remoteUid)"
        if key != boundRemoteBindingKey {
          DingRtcBridge.bindMeetingVideoView(surface, role: "remote", userId: remoteUid)
          boundRemoteBindingKey = key
        }
      } else {
        remoteTile?.avatar.isHidden = false
        remoteTile?.captionLabel.stringValue = remoteUid.isEmpty
          ? (callingNames.isEmpty ? "等待对方加入" : "呼叫中...")
          : peer
        boundRemoteBindingKey = nil
      }
    }

    let remoteCount = remoteIds.isEmpty ? (remoteUid.isEmpty ? 0 : 1) : remoteIds.count
    // 1v1（含 agent 1v1，remoteCount+callingNames<=1）：跟主画面块口径一致，用
    // displayPeer/displayPeerAvatar 兜底——joined/callingParticipantNames 靠 uid 反查身份，
    // 反查失败/无从反查（agent 不在 uid 表里）时会退化成"成员 1"且头像为空，主画面块的
    // peer 口径已经处理过这些兜底，直接复用避免侧栏和主画面显示不一致。
    let joinedDisplay: [(name: String, avatar: String)]
    let callingDisplay: [(name: String, avatar: String)]
    if remoteCount + callingNames.count <= 1 {
      if !remoteUid.isEmpty {
        joinedDisplay = [(displayPeer, displayPeerAvatar)]
        callingDisplay = []
      } else if !callingNames.isEmpty {
        joinedDisplay = []
        callingDisplay = [(displayPeer, displayPeerAvatar)]
      } else {
        joinedDisplay = []
        callingDisplay = []
      }
    } else {
      joinedDisplay = (0..<joinedNames.count).map { (joinedNames[$0], avatarAt(joinedAvatars, $0)) }
      callingDisplay = (0..<callingNames.count).map { (callingNames[$0], avatarAt(callingAvatars, $0)) }
    }
    renderParticipantRows(selfName: selfName, selfAvatarUrl: selfAvatarUrl, muted: muted,
                          joined: joinedDisplay, calling: callingDisplay)
    participantsLabel?.stringValue = "参会人 \(1 + remoteCount + callingNames.count)"

    // 设备 picker 列表（菜单按需读取）。
    micDevices = (s["microphoneDevices"] as? [[String: Any]]) ?? []
    speakerDevices = (s["speakerDevices"] as? [[String: Any]]) ?? []
    cameraDevices = (s["cameraDevices"] as? [[String: Any]]) ?? []
    speakerSupported = (s["speakerSupported"] as? Bool) ?? true

    // 网络状态：真实 callback 驱动；未收到 → 中性「已连接」，不伪造「网络良好」。
    let net = (s["networkText"] as? String) ?? "已连接"
    networkLabel?.stringValue = networkBars(net)
    networkLabel?.textColor = networkColor(net)
    networkLabel?.toolTip = net

    // 屏幕共享：按钮状态 + presenter 横幅。
    screenSharingNow = (s["screenSharing"] as? Bool) ?? false
    screenShareSources = (s["screenShareSources"] as? [[String: Any]]) ?? []
    let shareBusy = (s["screenShareBusy"] as? Bool) ?? false
    applyShareButton(sharing: screenSharingNow, busy: shareBusy)
    applyShareBanner(localSharing: screenSharingNow, remoteSharing: remoteSharing)
    updateShareControlPanel(
      localSharing: screenSharingNow,
      busy: shareBusy,
      muted: muted,
      cameraOn: cameraOn
    )

    applyLayout(layout)
    applyPanel(panelOpenState)
  }

  private func applyShareButton(sharing: Bool, busy: Bool) {
    guard let b = shareBtn else { return }
    shareLabel?.stringValue = sharing ? "停止共享" : "共享"
    b.isEnabled = !busy
    b.alphaValue = busy ? 0.5 : 1.0
    if sharing {
      b.layer?.backgroundColor = kBrand.cgColor // 共享中高亮
      b.contentTintColor = .white
      shareLabel?.textColor = kBrand
      setButtonGlyph(b, symbol: "rectangle.on.rectangle.slash", fallback: "停", tint: .white)
    } else {
      b.layer?.backgroundColor = NSColor(red: 0.955, green: 0.965, blue: 0.980, alpha: 1).cgColor
      b.contentTintColor = NSColor(white: 0.2, alpha: 1)
      shareLabel?.textColor = NSColor(white: 0.4, alpha: 1)
      setButtonGlyph(b, symbol: "rectangle.on.rectangle", fallback: "享", tint: NSColor(white: 0.2, alpha: 1))
    }
  }

  private func applyShareBanner(localSharing: Bool, remoteSharing: Bool) {
    guard let banner = shareBanner else { return }
    if localSharing {
      banner.stringValue = "  你正在共享屏幕  "
      banner.layer?.backgroundColor = kBrand.cgColor
      banner.isHidden = false
    } else if remoteSharing {
      banner.stringValue = "  对方正在共享屏幕  "
      banner.layer?.backgroundColor = NSColor(white: 0.25, alpha: 0.92).cgColor
      banner.isHidden = false
    } else {
      banner.isHidden = true
    }
  }

  private func updateShareControlPanel(localSharing: Bool, busy: Bool, muted: Bool, cameraOn: Bool) {
    guard localSharing else {
      hideShareControlPanel()
      return
    }
    if shareControlPanel == nil {
      buildShareControlPanel()
    }
    setButtonGlyph(shareControlMicBtn, symbol: muted ? "mic.slash.fill" : "mic.fill", fallback: muted ? "哑" : "麦", tint: NSColor(white: 0.2, alpha: 1))
    setButtonGlyph(shareControlCamBtn, symbol: cameraOn ? "video.fill" : "video.slash.fill", fallback: cameraOn ? "像" : "关", tint: NSColor(white: 0.2, alpha: 1))
    shareControlMicBtn?.toolTip = muted ? "取消静音" : "静音"
    shareControlCamBtn?.toolTip = cameraOn ? "关闭摄像头" : "打开摄像头"
    shareControlStopBtn?.isEnabled = !busy
    shareControlStopBtn?.alphaValue = busy ? 0.55 : 1.0
    updateShareControlDuration()
    positionShareControlPanelIfNeeded()
    shareControlPanel?.orderFrontRegardless()
  }

  private func buildShareControlPanel() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 430, height: 58),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true

    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
    root.layer?.cornerRadius = 12
    root.layer?.borderWidth = 1
    root.layer?.borderColor = NSColor(red: 0.86, green: 0.88, blue: 0.91, alpha: 1).cgColor
    root.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView = root

    let drag = makeLabel("⋮⋮", size: 14, color: NSColor(white: 0.45, alpha: 1), bold: true)
    drag.alignment = .center
    drag.translatesAutoresizingMaskIntoConstraints = false

    let status = makeLabel("你正在共享屏幕", size: 13, color: .white, bold: true)
    status.alignment = .center
    status.translatesAutoresizingMaskIntoConstraints = false
    let time = makeLabel("00:00", size: 13, color: .white, bold: true)
    time.alignment = .center
    time.translatesAutoresizingMaskIntoConstraints = false
    shareControlDurationLabel = time

    let statusPill = NSStackView(views: [status, time])
    statusPill.orientation = .horizontal
    statusPill.alignment = .centerY
    statusPill.spacing = 12
    statusPill.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
    statusPill.wantsLayer = true
    statusPill.layer?.backgroundColor = NSColor(red: 0.23, green: 0.68, blue: 0.36, alpha: 1).cgColor
    statusPill.layer?.cornerRadius = 8
    statusPill.translatesAutoresizingMaskIntoConstraints = false

    let mic = makeShareControlIconButton(symbol: "mic.fill", fallback: "麦", action: #selector(onShareControlMic))
    let cam = makeShareControlIconButton(symbol: "video.fill", fallback: "像", action: #selector(onShareControlCam))
    let stop = NSButton(title: "停止共享", target: self, action: #selector(onShareControlStop))
    stop.isBordered = false
    stop.bezelStyle = .regularSquare
    stop.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    stop.contentTintColor = .white
    stop.wantsLayer = true
    stop.layer?.backgroundColor = kHangup.cgColor
    stop.layer?.cornerRadius = 8
    stop.translatesAutoresizingMaskIntoConstraints = false
    stop.widthAnchor.constraint(equalToConstant: 88).isActive = true
    stop.heightAnchor.constraint(equalToConstant: 34).isActive = true
    shareControlMicBtn = mic
    shareControlCamBtn = cam
    shareControlStopBtn = stop

    let row = NSStackView(views: [drag, statusPill, mic, cam, stop])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
      row.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      drag.widthAnchor.constraint(equalToConstant: 22),
      statusPill.heightAnchor.constraint(equalToConstant: 34),
    ])
    shareControlPanel = panel
  }

  private func makeShareControlIconButton(symbol: String, fallback: String, action: Selector) -> NSButton {
    let b = NSButton()
    b.title = ""
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.wantsLayer = true
    b.layer?.backgroundColor = kControlBg.cgColor
    b.layer?.cornerRadius = 8
    b.contentTintColor = NSColor(white: 0.2, alpha: 1)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: 34).isActive = true
    b.heightAnchor.constraint(equalToConstant: 34).isActive = true
    b.target = self
    b.action = action
    setButtonGlyph(b, symbol: symbol, fallback: fallback, tint: NSColor(white: 0.2, alpha: 1))
    return b
  }

  private func updateShareControlDuration() {
    guard let start = startDate else { return }
    let sec = max(0, Int(Date().timeIntervalSince(start)))
    shareControlDurationLabel?.stringValue = String(format: "%02d:%02d", sec / 60, sec % 60)
  }

  private func positionShareControlPanelIfNeeded() {
    guard let panel = shareControlPanel, !panel.isVisible else { return }
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let size = panel.frame.size
    let x = frame.midX - size.width / 2
    let y = frame.minY + 28
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func hideShareControlPanel() {
    shareControlPanel?.orderOut(nil)
  }

  private func networkColor(_ text: String) -> NSColor {
    switch text {
    case "网络良好":
      return NSColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1)
    case "网络一般":
      return NSColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)
    case "网络较差", "网络中断":
      return kHangup
    default:
      return kSub // 「已连接」等中性
    }
  }

  private func networkBars(_ text: String) -> String {
    switch text {
    case "网络良好":
      return "▮▮▮"
    case "网络一般", "网络较差":
      return "▮▮▯"
    case "网络中断":
      return "▮▯▯"
    default:
      return "▮▮▮"
    }
  }

  private func startTimer() {
    timer?.invalidate()
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    tick()
  }

  private func tick() {
    guard let start = startDate else { return }
    let sec = max(0, Int(Date().timeIntervalSince(start)))
    durationLabel?.stringValue = String(format: "%02d:%02d", sec / 60, sec % 60)
    updateShareControlDuration()
  }

  private func hideWindow() {
    timer?.invalidate()
    timer = nil
    startDate = nil
    boundRemoteBindingKey = nil
    window?.orderOut(nil)
    hideShareControlPanel()
    // F16 v0.7 会议能力清理: 离组/关字幕/关白板 (best-effort, 不阻断挂断)。
    if let engine = DingRtcBridge.sharedEngine() {
      if let g = currentAudioGroup { _ = engine.leaveAudioGroup(g) }
      if subtitleOn { _ = engine.getSubtitleManager()?.enableSubtitle(false) }
    }
    currentAudioGroup = nil
    pendingAudioGroup = nil
    denoiseOn = false
    subtitleWaitTimer?.invalidate()
    subtitleWaitTimer = nil
    setSubtitleVisible(false, text: nil)
    subtitleOn = false
    if let sid = chatSessionId { DingRtcBridge.rtmLeaveSession(sid) }
    chatSessionId = nil
    chatSessionJoined = false
    if discussionOpen { setDiscussionOpen(false) } // 收回拼接宽度 + 约束复位
    discussionEmpty?.isHidden = false
    lastChatMsgDate = nil
    discussionStack?.arrangedSubviews.forEach { $0.removeFromSuperview() }
    teardownWhiteboard()
    // engine 生命周期由 DingRtcBridge 管（reset 时 releaseVideoCapture），此处不动 engine。
  }

  // MARK: 动作

  @objc private func onMic() { emit("toggleMute") }
  @objc private func onCam() { emit("toggleCamera") }
  @objc private func onHangup() { emit("hangUp") }
  @objc private func onLayout() { emit("switchLayout") }
  @objc private func onToggleParticipants() { emit("toggleParticipants") }
  @objc private func onInvite() { emit("invite") }
  @objc private func onShareControlMic() { emit("toggleMute") }
  @objc private func onShareControlCam() { emit("toggleCamera") }
  @objc private func onShareControlStop() { emitScreenShareRequest(start: false, sourceId: nil) }
  // 回到默认位置：纯 UI（重新居中窗口），不涉及业务状态。
  @objc private func onRestore() { window?.center() }

  // 设备菜单（真实）：mic/camera chevron 与 speaker 主键弹出设备列表，点选回传 selectDevice。
  @objc private func onMicMenu(_ sender: NSView) {
    showDeviceMenu(kind: "microphone", devices: micDevices, from: sender)
  }
  @objc private func onCamMenu(_ sender: NSView) {
    showDeviceMenu(kind: "camera", devices: cameraDevices, from: sender)
  }
  @objc private func onSpeakerMenu(_ sender: NSView) {
    if speakerSupported {
      showDeviceMenu(kind: "speaker", devices: speakerDevices, from: sender)
    } else {
      showInfoMenu("扬声器选择暂未支持", from: sender)
    }
  }

  private func showDeviceMenu(kind: String, devices: [[String: Any]], from sender: NSView) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    addMenuHeader(deviceMenuTitle(kind), to: menu)
    if devices.isEmpty {
      let item = NSMenuItem(title: "未检测到设备", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.attributedTitle = NSAttributedString(
        string: "未检测到设备",
        attributes: [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: kSub,
        ])
      menu.addItem(item)
      showMenu(menu, from: sender)
      return
    }
    for d in devices {
      let id = (d["id"] as? String) ?? ""
      if id.isEmpty { continue }
      let name = (d["name"] as? String) ?? id
      let item = NSMenuItem(title: name, action: #selector(onDevicePicked(_:)), keyEquivalent: "")
      item.target = self
      item.state = ((d["is_current"] as? Bool) ?? false) ? .on : .off
      item.representedObject = ["kind": kind, "deviceId": id]
      item.attributedTitle = NSAttributedString(
        string: name,
        attributes: [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: kInk,
        ])
      menu.addItem(item)
    }
    showMenu(menu, from: sender)
  }

  private func showInfoMenu(_ text: String, from sender: NSView) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: kSub,
      ])
    menu.addItem(item)
    showMenu(menu, from: sender)
  }

  private func deviceMenuTitle(_ kind: String) -> String {
    switch kind {
    case "microphone":
      return "选择麦克风"
    case "camera":
      return "选择摄像头"
    case "speaker":
      return "选择扬声器"
    default:
      return "选择设备"
    }
  }

  private func addMenuHeader(_ title: String, to menu: NSMenu) {
    let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    header.isEnabled = false
    header.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: kSub,
      ])
    menu.addItem(header)
    menu.addItem(.separator())
  }

  private func showMenu(_ menu: NSMenu, from sender: NSView) {
    menu.popUp(positioning: nil, at: NSPoint(x: -8, y: sender.bounds.height + 6), in: sender)
  }

  @objc private func onDevicePicked(_ sender: NSMenuItem) {
    guard let info = sender.representedObject as? [String: String],
      let kind = info["kind"], let id = info["deviceId"]
    else { return }
    emitDeviceSelection(kind: kind, deviceId: id)
  }

  /// 设备选择回传给 Dart（controller 调 RtcClient.selectDevice，成功后回 update 刷新当前）。
  private func emitDeviceSelection(kind: String, deviceId: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(["action": "selectDevice", "deviceKind": kind, "deviceId": deviceId])
    }
  }

  // 屏幕共享：共享中 → 直接停止；否则弹源菜单（整个屏幕 + 窗口列表），点选回传 start。
  @objc private func onShare(_ sender: NSView) {
    if screenSharingNow {
      emitScreenShareRequest(start: false, sourceId: nil)
      return
    }
    let menu = NSMenu()
    // 默认项：共享整个屏幕（sourceId 空 → native 取首个桌面，可触发权限弹窗）。
    let whole = NSMenuItem(title: "共享整个屏幕", action: #selector(onScreenSourcePicked(_:)), keyEquivalent: "")
    whole.target = self
    whole.representedObject = ["sourceId": ""]
    menu.addItem(whole)
    // 具体源（屏幕/窗口）。
    let windows = screenShareSources.filter { ($0["kind"] as? String) == "window" }
    let screens = screenShareSources.filter { ($0["kind"] as? String) == "screen" }
    if !screens.isEmpty || !windows.isEmpty { menu.addItem(.separator()) }
    for src in screens + windows {
      let id = (src["id"] as? String) ?? ""
      if id.isEmpty { continue }
      let name = (src["name"] as? String) ?? id
      let item = NSMenuItem(title: name, action: #selector(onScreenSourcePicked(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = ["sourceId": id]
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func onScreenSourcePicked(_ sender: NSMenuItem) {
    let sid = (sender.representedObject as? [String: String])?["sourceId"] ?? ""
    emitScreenShareRequest(start: true, sourceId: sid.isEmpty ? nil : sid)
  }

  private func emitScreenShareRequest(start: Bool, sourceId: String?) {
    DispatchQueue.main.async { [weak self] in
      var payload: [String: Any] = ["action": "screenShareRequest", "start": start]
      if let sid = sourceId { payload["sourceId"] = sid }
      self?.eventSink?(payload)
    }
  }

  // 窗口关闭按钮 = 挂断（return false：交由 controller→reset→hide 收尾，避免双重关闭）。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // F16 v0.7: 白板独立窗口关闭 = 离开白板（不挂断会议）。
    if sender === whiteboardWindow {
      teardownWhiteboard()
      return true
    }
    emit("hangUp")
    return false
  }

  func windowDidResize(_ notification: Notification) {
    if let window = notification.object as? NSWindow {
      positionTrafficLights(in: window)
    }
  }

  // MARK: F16 v0.7 会议能力扩展（feature §7.6 / TDD v0.3.27；状态真实、失败回滚、不假成功）

  /// 「更多」菜单：分组讨论 / 智能降噪 / 智能纪要 / 实时字幕 / 互动白板。
  @objc private func onMoreMenu(_ sender: NSButton) {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let group = NSMenuItem(title: "分组讨论", action: nil, keyEquivalent: "")
    let groupMenu = NSMenu()
    groupMenu.autoenablesItems = false
    let hall = NSMenuItem(title: "大厅（全员）", action: #selector(onSelectHall), keyEquivalent: "")
    hall.target = self
    hall.state = currentAudioGroup == nil ? .on : .off
    groupMenu.addItem(hall)
    groupMenu.addItem(.separator())
    for i in 1...3 {
      let item = NSMenuItem(title: "分组 \(i)", action: #selector(onSelectGroup(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = "easyo_group_\(i)"
      item.state = currentAudioGroup == "easyo_group_\(i)" ? .on : .off
      groupMenu.addItem(item)
    }
    group.submenu = groupMenu
    menu.addItem(group)

    let denoise = NSMenuItem(title: "智能降噪（即将推出）", action: nil, keyEquivalent: "")
    denoise.isEnabled = false
    menu.addItem(denoise)

    let minutes = NSMenuItem(title: "智能纪要（即将推出）", action: nil, keyEquivalent: "")
    minutes.isEnabled = false
    menu.addItem(minutes)

    let subtitle = NSMenuItem(title: "实时字幕（即将推出）", action: nil, keyEquivalent: "")
    subtitle.isEnabled = false
    menu.addItem(subtitle)

    let whiteboard = NSMenuItem(title: "互动白板（即将推出）", action: nil, keyEquivalent: "")
    whiteboard.isEnabled = false
    menu.addItem(whiteboard)

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
  }

  private func meetingEngine(toastFrom sender: NSView?) -> DingRtcEngine? {
    guard let engine = DingRtcBridge.sharedEngine() else {
      if let s = sender ?? moreBtn { showInfoMenu("RTC 引擎未就绪", from: s) }
      return nil
    }
    return engine
  }

  // ── 智能降噪（端侧 setAudioDenoise；失败不翻状态） ──
  @objc private func onToggleDenoise(_ sender: NSMenuItem) {
    guard let engine = meetingEngine(toastFrom: moreBtn) else { return }
    let opts = DingRtcAudioDenoiseOptions()
    opts.mode = denoiseOn ? .off : .enhance
    let rc = engine.setAudioDenoise(opts)
    if rc == 0 {
      denoiseOn.toggle()
      NSLog("[F16 RTC Native] denoise toggled on=\(denoiseOn)")
    } else if let s = moreBtn {
      // 智能降噪依赖 libhbal_se.dylib + .nn 模型随包; rc!=0 多为资源缺失/场景不支持。
      showInfoMenu(denoiseOn ? "关闭智能降噪失败(\(rc))" : "缺少智能降噪资源或暂不可用(\(rc))", from: s)
    }
  }

  // ── 实时字幕（依赖服务端 StartCloudNote；status 回调诚实回滚） ──
  @objc private func onToggleSubtitle() {
    guard let engine = meetingEngine(toastFrom: captionBtn) else { return }
    guard let mgr = engine.getSubtitleManager() else {
      if let s = captionBtn { showInfoMenu("字幕服务不可用（SDK 未提供）", from: s) }
      return
    }
    if subtitleOn {
      subtitleWaitTimer?.invalidate()
      subtitleWaitTimer = nil
      _ = mgr.enableSubtitle(false)
      subtitleOn = false
      setSubtitleVisible(false, text: nil)
      return
    }
    mgr.setDelegate(self)
    let rc = mgr.enableSubtitle(true)
    if rc == 0 {
      subtitleOn = true
      setSubtitleVisible(true, text: "字幕已开启，等待语音…")
      // 字幕数据依赖服务端 StartCloudNote 任务; 迟迟无数据 → 诚实回滚, 不留悬空"等待中"。
      subtitleWaitTimer?.invalidate()
      subtitleWaitTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
        guard let self = self, self.subtitleOn else { return }
        _ = DingRtcBridge.sharedEngine()?.getSubtitleManager()?.enableSubtitle(false)
        self.subtitleOn = false
        self.setSubtitleVisible(false, text: nil)
        if let s = self.captionBtn {
          self.showInfoMenu("未收到字幕数据：字幕服务可能未开通（需服务端启动智能纪要任务）", from: s)
        }
      }
    } else if let s = captionBtn {
      showInfoMenu("开启字幕失败(\(rc))", from: s)
    }
  }

  private func setSubtitleVisible(_ visible: Bool, text: String?) {
    subtitleBar?.isHidden = !visible
    if let t = text { subtitleBar?.stringValue = t }
    if !visible { subtitleBar?.stringValue = "" }
  }

  // ── 分组讨论 MVP（固定组 1/2/3 + 大厅；音频组隔离真实生效） ──
  @objc private func onSelectHall() { applyAudioGroup(nil) }

  @objc private func onSelectGroup(_ sender: NSMenuItem) {
    guard let groupId = sender.representedObject as? String else { return }
    applyAudioGroup(groupId)
  }

  private func applyAudioGroup(_ groupId: String?) {
    guard let engine = meetingEngine(toastFrom: moreBtn) else { return }
    ensureAudioGroupObserver()
    if let g = groupId {
      if g == currentAudioGroup || g == pendingAudioGroup { return }
      if let old = currentAudioGroup { _ = engine.leaveAudioGroup(old) }
      currentAudioGroup = nil
      // join 是异步受理 (SDK: mix/switch 前提是"已在目标组") → 这里只 join,
      // mix+switch 在 onAudioGroupJoinResult 成功后做 (见 handleAudioGroupEvent)。
      let rcJoin = engine.joinAudioGroup(g, usrData: nil)
      guard rcJoin == 0 else {
        pendingAudioGroup = nil
        if let s = moreBtn { showInfoMenu("加入分组失败(\(rcJoin))", from: s) }
        return
      }
      pendingAudioGroup = g
      NSLog("[F16 RTC Native] audio group join requested \(g)")
    } else {
      if let old = currentAudioGroup { _ = engine.leaveAudioGroup(old) }
      pendingAudioGroup = nil
      _ = engine.switchSubscription(toAudioGroup: nil)
      currentAudioGroup = nil
      NSLog("[F16 RTC Native] audio group back to hall")
    }
  }

  private func ensureAudioGroupObserver() {
    guard audioGroupObserver == nil else { return }
    audioGroupObserver = NotificationCenter.default.addObserver(
      forName: .easyoAudioGroupEvent, object: nil, queue: .main
    ) { [weak self] note in
      self?.handleAudioGroupEvent(note.userInfo ?? [:])
    }
  }

  private func handleAudioGroupEvent(_ info: [AnyHashable: Any]) {
    let op = info["op"] as? String ?? ""
    let result = info["result"] as? Int ?? -1
    let group = info["group"] as? String ?? ""
    switch op {
    case "join":
      guard group == pendingAudioGroup else { return }
      pendingAudioGroup = nil
      guard result == 0 else {
        if let s = moreBtn { showInfoMenu("加入分组失败(\(result))", from: s) }
        return
      }
      guard let engine = DingRtcBridge.sharedEngine() else { return }
      // 已确认在组内 → 把本地音频 mix 进组 + 订阅切到组。
      let rcMix = engine.mixAudio(toGroup: group, mix: true)
      let rcSub = engine.switchSubscription(toAudioGroup: group)
      if rcMix != 0 || rcSub != 0 {
        _ = engine.leaveAudioGroup(group)
        _ = engine.switchSubscription(toAudioGroup: nil)
        if let s = moreBtn { showInfoMenu("分组音频切换失败(mix=\(rcMix) sub=\(rcSub))", from: s) }
        return
      }
      currentAudioGroup = group
      NSLog("[F16 RTC Native] audio group active \(group)")
    case "mix":
      if result != 0, group == currentAudioGroup {
        if let s = moreBtn { showInfoMenu("分组混音失败(\(result))，已回大厅", from: s) }
        applyAudioGroup(nil)
      }
    default:
      break
    }
  }

  // ── 表情回应（飞书式，RTM 同通道广播 {"r":emoji,"n":昵称}；双端 stage 飘起动画） ──
  @objc private func onReactionThumb() { sendReaction("👍") }
  @objc private func onReactionOK() { sendReaction("👌") }

  @objc private func onReactionMenu(_ sender: NSButton) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let emojis = ["😀", "😂", "👏", "❤️", "🎉", "😮", "🙏", "👋"]
    let row = NSMenuItem(title: emojis.joined(separator: "  "), action: nil, keyEquivalent: "")
    row.isEnabled = false
    for e in emojis {
      let item = NSMenuItem(title: e, action: #selector(onReactionPick(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = e
      menu.addItem(item)
    }
    _ = row
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
  }

  @objc private func onReactionPick(_ sender: NSMenuItem) {
    guard let e = sender.representedObject as? String else { return }
    sendReaction(e)
  }

  private func sendReaction(_ emoji: String) {
    ensureChatSession()
    guard chatSessionJoined, let sid = chatSessionId else {
      pendingReaction = emoji
      return
    }
    var name = selfRowName?.stringValue ?? "我"
    name = name.replacingOccurrences(of: " (我)", with: "").replacingOccurrences(of: "（我）", with: "")
    guard let data = try? JSONSerialization.data(withJSONObject: ["r": emoji, "n": name]) else { return }
    let rc = DingRtcBridge.rtmBroadcast(sid, data: data)
    if rc == 0 {
      showReactionFloat(emoji, name: name.isEmpty ? "我" : name)
    } else if let s = reactionMenuBtn {
      showInfoMenu("表情发送失败(\(rc))，稍后再试", from: s)
    }
  }

  /// 左下角轻量反应键（A1/A2）: 无框、emoji 原色 / OK 橙色粗体 / SF icon；28pt 高紧凑。
  private func makeReactionButton(text: String, tooltip: String, action: Selector,
                                  isOK: Bool = false, symbol: String? = nil) -> NSButton {
    let b = FixedSizeButton()
    b.fixedSize = NSSize(width: isOK ? Self.toolbarButtonSize.width : 34, height: Self.toolbarButtonSize.height)
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.wantsLayer = true
    b.layer?.backgroundColor = NSColor.clear.cgColor
    b.layer?.cornerRadius = Self.toolbarButtonCornerRadius
    b.translatesAutoresizingMaskIntoConstraints = false
    // 与中央工具键同高同级 (飞书整行等高), 仅底色透明区分轻重。
    b.widthAnchor.constraint(equalToConstant: isOK ? Self.toolbarButtonSize.width : 34).isActive = true
    b.heightAnchor.constraint(equalToConstant: Self.toolbarButtonSize.height).isActive = true
    if let sym = symbol, let img = symbolImage(sym) {
      b.contentTintColor = NSColor(white: 0.25, alpha: 1)
      installCenteredImage(img, in: b, tint: NSColor(white: 0.25, alpha: 1), side: 17)
    } else {
      if isOK {
        installCenteredText("OK", in: b, font: NSFont.systemFont(ofSize: 13, weight: .heavy),
                            color: NSColor.systemOrange)
      } else {
        installCenteredText(text, in: b, font: NSFont.systemFont(ofSize: 18),
                            color: NSColor.labelColor)
      }
    }
    b.target = self
    b.action = action
    b.toolTip = tooltip
    b.setAccessibilityLabel(tooltip)
    return b
  }

  /// 飞书式表情飘浮（A4: emoji + 发送者名字小标签）: stage 左下角升起 + 渐隐。不改 stage 布局。
  private func showReactionFloat(_ emoji: String, name: String) {
    guard let stageView = stage else { return }
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .centerX
    container.spacing = 2
    let face = NSTextField(labelWithString: emoji)
    face.font = NSFont.systemFont(ofSize: 30)
    let who = NSTextField(labelWithString: name)
    who.font = NSFont.systemFont(ofSize: 10)
    who.textColor = .white
    who.wantsLayer = true
    who.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
    who.layer?.cornerRadius = 7
    who.alignment = .center
    container.addArrangedSubview(face)
    container.addArrangedSubview(who)
    let startX = CGFloat(28) + CGFloat(arc4random_uniform(56))
    container.frame = NSRect(x: startX, y: 18, width: 72, height: 60)
    stageView.addSubview(container)
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 1.8
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      container.animator().frame = container.frame.offsetBy(dx: CGFloat(arc4random_uniform(30)) - 15, dy: 150)
      container.animator().alphaValue = 0
    }, completionHandler: {
      container.removeFromSuperview()
    })
  }

  // ── 会中讨论（RTM session broadcast；会中临时讨论，不持久化到 IM — 持久化 defer） ──
  @objc private func onToggleDiscussion() {
    if discussionOpen {
      setDiscussionOpen(false)
      return
    }
    guard DingRtcBridge.sharedEngine() != nil else {
      if let s = captionBtn { showInfoMenu("RTC 引擎未就绪", from: s) }
      return
    }
    if discussionPanel == nil { buildDiscussionPanel() }
    ensureChatSession()
    // 与参会人侧栏互斥：参会人开着 → 经 Dart 状态正路关掉（emit），讨论立即展开。
    if panelOpen { emit("toggleParticipants") }
    refreshDiscussionHeader()
    setDiscussionOpen(true)
    window?.makeFirstResponder(discussionInput)
  }

  private func setDiscussionOpen(_ open: Bool) {
    guard discussionOpen != open else { return }
    discussionOpen = open
    discussionPanel?.isHidden = !open
    // 飞书式「拼接」：窗口向右加宽一个面板位，画面区保持原宽，不从现有宽度里切。
    resizeWindowForDiscussion(open: open)
    applyStageTrailing()
  }

  private let discussionPanelWidth: CGFloat = 300

  private func resizeWindowForDiscussion(open: Bool) {
    guard let win = window else { return }
    var f = win.frame
    if open {
      f.size.width += discussionPanelWidth
      // 超出屏幕右缘 → 左移补偿（夹在可见区内）。
      if let vis = win.screen?.visibleFrame, f.maxX > vis.maxX {
        f.origin.x = max(vis.minX, f.origin.x - (f.maxX - vis.maxX))
      }
    } else {
      f.size.width = max(f.size.width - discussionPanelWidth, 640)
    }
    win.setFrame(f, display: true, animate: true)
  }

  /// B2/D1: 1v1 用对端名字+头像首字做标题（飞书同款）；取不到回落「讨论」。
  private func refreshDiscussionHeader() {
    let name = lastPeerName.isEmpty || lastPeerName == "对方" ? "讨论" : lastPeerName
    discussionTitle?.stringValue = name
    let initial = String(name.prefix(1))
    discussionAvatar?.stringValue = initial == "讨" ? "聊" : initial
  }

  private func ensureChatSession() {
    guard !chatSessionJoined, !chatSessionJoining else { return }
    guard let channel = DingRtcBridge.currentChannelId else {
      if let s = captionBtn { showInfoMenu("频道未就绪，稍后再试", from: s) }
      return
    }
    let sid = "easyo_chat_\(channel)"
    chatSessionId = sid
    chatSessionJoining = true
    ensureRtmChatObservers()
    let rc = DingRtcBridge.rtmJoinSession(sid)
    if rc != 0 {
      chatSessionJoining = false
      if let s = captionBtn {
        showInfoMenu("加入讨论失败(\(rc))", from: s)
      }
    }
  }

  private func ensureRtmChatObservers() {
    if rtmJoinObserver == nil {
      rtmJoinObserver = NotificationCenter.default.addObserver(
        forName: .easyoRtmSessionJoin, object: nil, queue: .main
      ) { [weak self] note in
        guard let self = self,
              let sid = note.userInfo?["sessionId"] as? String, sid == self.chatSessionId else { return }
        let result = note.userInfo?["result"] as? Int ?? -1
        self.chatSessionJoined = (result == 0)
        self.chatSessionJoining = false
        if result == 0, let emoji = self.pendingReaction {
          self.pendingReaction = nil
          self.sendReaction(emoji)
        }
        if result != 0, let s = self.captionBtn {
          self.showInfoMenu("加入讨论失败(\(result))", from: s)
        }
      }
    }
    if rtmChatObserver == nil {
      rtmChatObserver = NotificationCenter.default.addObserver(
        forName: .easyoRtmChatMessage, object: nil, queue: .main
      ) { [weak self] note in
        guard let self = self,
              let sid = note.userInfo?["sessionId"] as? String, sid == self.chatSessionId,
              let uid = note.userInfo?["uid"] as? String,
              let data = note.userInfo?["data"] as? Data else { return }
        if uid == DingRtcBridge.currentUserId { return } // 自己的消息发送时已本地上屏
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let emoji = obj["r"] as? String {
          let who = (obj["n"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"
          self.showReactionFloat(emoji, name: who)
          return
        }
        guard let text = obj["t"] as? String else { return }
        let name = (obj["n"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "对方"
        self.appendChatRow(name: name, text: text, mine: false)
      }
    }
  }

  private func buildDiscussionPanel() {
    guard let stageView = stage, let content = window?.contentView,
          let header = headerView, let toolbar = toolbarView else { return }
    let panel = NSView()
    panel.wantsLayer = true
    // S1: 飞书式浅灰内容底（更浅, 用户反馈原 #F7F8FA 偏深）。
    panel.layer?.backgroundColor = NSColor(red: 0.984, green: 0.986, blue: 0.992, alpha: 1).cgColor
    panel.translatesAutoresizingMaskIntoConstraints = false
    // 左缘细分隔线（与参会人侧栏一致的轻量感）
    let hairline = NSView()
    hairline.wantsLayer = true
    hairline.layer?.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
    hairline.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(hairline)

    // B2: 头像首字 + 名字（1v1 取对端名）；容器圆+居中文字, 不跑偏。
    let (avatar, avatarLabel) = makeInitialAvatar("聊", diameter: 22,
                                                  bg: NSColor(red: 0.45, green: 0.73, blue: 0.25, alpha: 1))
    discussionAvatar = avatarLabel

    let title = makeLabel("讨论", size: 13, color: NSColor(white: 0.2, alpha: 1), bold: true)
    title.translatesAutoresizingMaskIntoConstraints = false
    discussionTitle = title
    let close = NSButton()
    close.title = "✕"
    close.isBordered = false
    close.font = NSFont.systemFont(ofSize: 12)
    close.contentTintColor = NSColor(white: 0.45, alpha: 1)
    close.target = self
    close.action = #selector(onToggleDiscussion)
    close.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    let flipped = FlippedClipView()
    flipped.translatesAutoresizingMaskIntoConstraints = false
    flipped.addSubview(stack)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = flipped
    scroll.translatesAutoresizingMaskIntoConstraints = false

    // S2: 头部分隔线。
    let headerSep = NSView()
    headerSep.wantsLayer = true
    headerSep.layer?.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
    headerSep.translatesAutoresizingMaskIntoConstraints = false

    // S5/S6/S7: 圆角输入卡片（白底描边）+ 可换行输入 + 箭头发送（空内容禁用）。
    let inputCard = NSView()
    inputCard.wantsLayer = true
    inputCard.layer?.backgroundColor = NSColor.white.cgColor
    inputCard.layer?.cornerRadius = 8
    inputCard.layer?.borderWidth = 1
    inputCard.layer?.borderColor = NSColor(white: 0.88, alpha: 1).cgColor
    inputCard.translatesAutoresizingMaskIntoConstraints = false

    let input = NSTextField()
    input.placeholderString = "发送会中消息…"
    input.font = NSFont.systemFont(ofSize: 12)
    input.isBordered = false
    input.focusRingType = .none
    input.drawsBackground = false
    input.usesSingleLineMode = false
    input.cell?.wraps = true
    input.maximumNumberOfLines = 3
    input.delegate = self
    input.target = self
    input.action = #selector(onSendDiscussion)
    input.translatesAutoresizingMaskIntoConstraints = false

    let send = NSButton()
    send.isBordered = false
    send.bezelStyle = .regularSquare
    if let img = symbolImage("paperplane.fill") {
      send.image = img
      send.imagePosition = .imageOnly
    } else {
      send.title = "➤"
    }
    send.contentTintColor = NSColor(white: 0.72, alpha: 1) // 空内容禁用灰
    send.isEnabled = false
    send.target = self
    send.action = #selector(onSendDiscussion)
    send.translatesAutoresizingMaskIntoConstraints = false
    discussionSendBtn = send

    // B6: 空状态提示（首条消息出现时隐藏）。
    let empty = makeLabel("还没有消息，来说点什么吧", size: 12, color: NSColor(white: 0.62, alpha: 1))
    empty.translatesAutoresizingMaskIntoConstraints = false
    discussionEmpty = empty

    panel.addSubview(avatar)
    panel.addSubview(title)
    panel.addSubview(close)
    panel.addSubview(headerSep)
    panel.addSubview(scroll)
    panel.addSubview(empty)
    inputCard.addSubview(input)
    inputCard.addSubview(send)
    panel.addSubview(inputCard)
    // P1: 挂 contentView 通顶通底（飞书式整列）；开启时 stage/header/toolbar 右缘全部收到面板左缘。
    content.addSubview(panel)
    discussionOpenConstraints = [
      stageView.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
    ]

    NSLayoutConstraint.activate([
      panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      panel.topAnchor.constraint(equalTo: content.topAnchor),
      panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      panel.widthAnchor.constraint(equalToConstant: 300),
      hairline.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
      hairline.topAnchor.constraint(equalTo: panel.topAnchor),
      hairline.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
      hairline.widthAnchor.constraint(equalToConstant: 1),

      avatar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
      avatar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
      title.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
      close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
      empty.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
      empty.centerYAnchor.constraint(equalTo: panel.centerYAnchor),

      headerSep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 11),
      headerSep.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
      headerSep.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
      headerSep.heightAnchor.constraint(equalToConstant: 1),

      scroll.topAnchor.constraint(equalTo: headerSep.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
      scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
      scroll.bottomAnchor.constraint(equalTo: inputCard.topAnchor, constant: -8),

      flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      flipped.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      flipped.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
      stack.topAnchor.constraint(equalTo: flipped.topAnchor),
      flipped.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor),

      inputCard.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
      inputCard.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
      inputCard.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
      inputCard.heightAnchor.constraint(equalToConstant: 60),
      input.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor, constant: 10),
      input.topAnchor.constraint(equalTo: inputCard.topAnchor, constant: 9),
      input.bottomAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: -9),
      input.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -6),
      send.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor, constant: -8),
      send.bottomAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: -7),
      send.widthAnchor.constraint(equalToConstant: 24),
      send.heightAnchor.constraint(equalToConstant: 22),
    ])
    discussionPanel = panel
    discussionStack = stack
    discussionScroll = scroll
    discussionInput = input
  }

  @objc private func onSendDiscussion() {
    guard let input = discussionInput else { return }
    let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard let sid = chatSessionId else {
      ensureChatSession()
      return
    }
    var name = selfRowName?.stringValue ?? "我"
    name = name.replacingOccurrences(of: " (我)", with: "").replacingOccurrences(of: "（我）", with: "")
    if name.isEmpty { name = "我" }
    guard let data = try? JSONSerialization.data(withJSONObject: ["n": name, "t": text]) else { return }
    let rc = DingRtcBridge.rtmBroadcast(sid, data: data)
    if rc == 0 {
      appendChatRow(name: name.isEmpty ? "我" : name, text: text, mine: true)
      input.stringValue = ""
      updateDiscussionSendEnabled()
    } else if let s = captionBtn {
      showInfoMenu("发送失败(\(rc))", from: s)
    }
  }

  /// 首字头像: 圆形容器 + **居中**文字 (NSTextField 直接设 cornerRadius 会基线偏移)。
  private func makeInitialAvatar(_ initial: String, diameter: CGFloat, bg: NSColor) -> (view: NSView, label: NSTextField) {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = bg.cgColor
    v.layer?.cornerRadius = diameter / 2
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: diameter).isActive = true
    v.heightAnchor.constraint(equalToConstant: diameter).isActive = true
    let lab = makeLabel(initial, size: max(9, diameter * 0.45), color: .white, bold: true)
    lab.alignment = .center
    lab.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(lab)
    lab.centerXAnchor.constraint(equalTo: v.centerXAnchor).isActive = true
    lab.centerYAnchor.constraint(equalTo: v.centerYAnchor).isActive = true
    return (v, lab)
  }

  func updateDiscussionSendEnabled() {
    let has = !(discussionInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    discussionSendBtn?.isEnabled = has
    discussionSendBtn?.contentTintColor = has ? kBrand : NSColor(white: 0.72, alpha: 1)
  }

  private func appendChatRow(name: String, text: String, mine: Bool) {
    guard let stack = discussionStack else { return }
    discussionEmpty?.isHidden = true

    // D4: 时间分割 — 首条或距上条 ≥5 分钟，插居中 HH:mm 小灰字。
    let now = Date()
    if lastChatMsgDate == nil || now.timeIntervalSince(lastChatMsgDate!) >= 300 {
      let fmt = DateFormatter()
      fmt.dateFormat = "HH:mm"
      let divider = makeLabel(fmt.string(from: now), size: 10, color: NSColor(white: 0.62, alpha: 1))
      divider.alignment = .center
      divider.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(divider)
      divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    lastChatMsgDate = now

    // S3/S4: 飞书式气泡 — 对方=头像+白色气泡靠左；自己=浅蓝气泡靠右（无头像）。
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false

    let bubble = NSView()
    bubble.wantsLayer = true
    bubble.layer?.cornerRadius = 10
    // P2: 飞书系配色 — 对方浅蓝 #E9F2FF、自己稍深 #CDE3FF, 左右+头像区分。
    bubble.layer?.backgroundColor = mine
      ? NSColor(red: 0.80, green: 0.89, blue: 1.0, alpha: 1).cgColor
      : NSColor(red: 0.91, green: 0.95, blue: 1.0, alpha: 1).cgColor
    bubble.translatesAutoresizingMaskIntoConstraints = false
    let msg = NSTextField(wrappingLabelWithString: text)
    msg.font = NSFont.systemFont(ofSize: 12)
    msg.textColor = NSColor(white: 0.15, alpha: 1)
    msg.isEditable = false
    msg.isBordered = false
    msg.drawsBackground = false
    msg.translatesAutoresizingMaskIntoConstraints = false
    bubble.addSubview(msg)
    row.addSubview(bubble)

    var cons: [NSLayoutConstraint] = [
      msg.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11),
      msg.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11),
      msg.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
      msg.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
      bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 210),
      bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
    ]
    if mine {
      // 自己也带头像（右侧, 品牌蓝底）— 单侧无头像时认不出谁发的。
      let (avatar, _) = makeInitialAvatar(String(name.prefix(1)), diameter: 20, bg: kBrand)
      row.addSubview(avatar)
      cons += [
        avatar.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
        avatar.topAnchor.constraint(equalTo: row.topAnchor),
        bubble.topAnchor.constraint(equalTo: row.topAnchor),
        bubble.trailingAnchor.constraint(equalTo: avatar.leadingAnchor, constant: -6),
      ]
    } else {
      // 对方: 头像首字圆(绿) + 名字小标签 + 气泡
      let (avatar, _) = makeInitialAvatar(String(name.prefix(1)), diameter: 20,
                                          bg: NSColor(red: 0.45, green: 0.73, blue: 0.25, alpha: 1))
      let who = makeLabel(name, size: 10, color: NSColor(white: 0.55, alpha: 1))
      who.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(avatar)
      row.addSubview(who)
      cons += [
        avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
        avatar.topAnchor.constraint(equalTo: row.topAnchor),
        who.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 6),
        who.topAnchor.constraint(equalTo: row.topAnchor),
        bubble.topAnchor.constraint(equalTo: who.bottomAnchor, constant: 3),
        bubble.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 6),
      ]
    }
    stack.addArrangedSubview(row)
    cons.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor))
    NSLayoutConstraint.activate(cons)

    // 滚到底
    if let docView = discussionScroll?.documentView {
      docView.layoutSubtreeIfNeeded()
      docView.scroll(NSPoint(x: 0, y: docView.bounds.height))
    }
  }

  // ── 智能纪要（无客户端 SDK API；服务端 StartCloudNote 后续里程碑，guarded 不假成功） ──
  @objc private func onMinutesInfo() {
    if let s = moreBtn { showInfoMenu("智能纪要需服务端开通（开发中）", from: s) }
  }

  // ── 互动白板（独立窗口；create → join → onWhiteboardStart → open） ──
  @objc private func onOpenWhiteboard() {
    if let w = whiteboardWindow {
      w.makeKeyAndOrderFront(nil)
      return
    }
    guard let engine = meetingEngine(toastFrom: moreBtn) else { return }
    let mgr = engine.getWhiteboardManager()
    mgr.setDelegate(self)
    let cfg = DingRtcWbConfig()
    cfg.mode = .basic
    cfg.width = 1920
    cfg.height = 1080
    let wb = mgr.createWhiteboard("easyo_wb_main", with: cfg)
    whiteboardObj = wb
    wb.setDelegate(self) // 白板对象事件 (onJoinResult → open)
    let rc = wb.join()
    guard rc == 0 else {
      whiteboardObj = nil
      if let s = moreBtn { showInfoMenu("加入白板失败(\(rc))", from: s) }
      return
    }
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "互动白板"
    win.isReleasedWhenClosed = false
    win.delegate = self
    win.center()
    let loading = makeLabel("白板加载中…", size: 13, color: NSColor(white: 0.45, alpha: 1))
    loading.translatesAutoresizingMaskIntoConstraints = false
    win.contentView?.addSubview(loading)
    if let cv = win.contentView {
      NSLayoutConstraint.activate([
        loading.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
        loading.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
      ])
    }
    whiteboardWindow = win
    win.makeKeyAndOrderFront(nil)
  }

  private func teardownWhiteboard() {
    if let wb = whiteboardObj {
      _ = wb.close()
      _ = wb.leave()
    }
    whiteboardObj = nil
    whiteboardWindow?.delegate = nil
    whiteboardWindow?.orderOut(nil)
    whiteboardWindow = nil
  }

  // MARK: 控件工厂

  private func makeLabel(_ text: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    l.textColor = color
    l.backgroundColor = .clear
    l.isBordered = false
    l.isEditable = false
    return l
  }

  private func clearButtonCellContent(_ button: NSButton) {
    button.subviews.forEach { $0.removeFromSuperview() }
    button.title = ""
    button.attributedTitle = NSAttributedString(string: "")
    button.image = nil
    button.imagePosition = .noImage
  }

  private func installCenteredImage(_ image: NSImage, in button: NSButton, tint: NSColor, side: CGFloat = 18) {
    clearButtonCellContent(button)
    let icon = NSImageView()
    icon.image = image
    icon.imageScaling = .scaleProportionallyDown
    icon.contentTintColor = tint
    icon.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: side),
      icon.heightAnchor.constraint(equalToConstant: side),
    ])
  }

  private func installCenteredText(_ text: String, in button: NSButton, font: NSFont, color: NSColor) {
    clearButtonCellContent(button)
    let glyph = NSTextField(labelWithString: text)
    glyph.font = font
    glyph.textColor = color
    glyph.alignment = .center
    glyph.backgroundColor = .clear
    glyph.isBordered = false
    glyph.isEditable = false
    glyph.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(glyph)
    NSLayoutConstraint.activate([
      glyph.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      glyph.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      glyph.widthAnchor.constraint(lessThanOrEqualTo: button.widthAnchor),
      glyph.heightAnchor.constraint(lessThanOrEqualTo: button.heightAnchor),
    ])
  }

  /// SF Symbol（macOS 11+）；低版本返回 nil → 用文字 fallback（部署目标 10.15）。
  private func symbolImage(_ name: String) -> NSImage? {
    if #available(macOS 11.0, *) {
      let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
      // 统一 14pt/medium: 不同 SF Symbol 固有视觉尺寸差异大 (麦克风/扬声器/电话…),
      // 不统一会让等高按钮看起来参差不齐。
      let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
      return img?.withSymbolConfiguration(cfg) ?? img
    }
    return nil
  }

  /// 给按钮设图标：有 SF Symbol 用图标，否则用单字文字（跨版本安全）。
  private func setButtonGlyph(_ button: NSButton?, symbol: String, fallback: String, tint: NSColor) {
    guard let b = button else { return }
    if let img = symbolImage(symbol) {
      installCenteredImage(img, in: b, tint: tint)
    } else {
      installCenteredText(fallback, in: b, font: NSFont.systemFont(ofSize: 15, weight: .medium), color: tint)
    }
  }

}

// MARK: - F16 v0.7 实时字幕回调（RtcMeetingWindowBridge；数据依赖服务端 StartCloudNote）
extension RtcMeetingWindowBridge: DingRtcEngineSubtitleManagerDelegate {
  func onSubtitleServiceStatusChanged(_ status: DingRtcSubtitleStatus) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      NSLog("[F16 RTC Native] subtitle status=\(status.rawValue)")
      if status == .error {
        // 诚实回滚：未开通服务端任务时 SDK 报错，不显示假字幕开启态。
        self.subtitleWaitTimer?.invalidate()
        self.subtitleWaitTimer = nil
        _ = DingRtcBridge.sharedEngine()?.getSubtitleManager()?.enableSubtitle(false)
        self.subtitleOn = false
        self.setSubtitleVisible(false, text: nil)
        if let s = self.captionBtn {
          self.showInfoMenu("字幕服务未开通（需服务端启动智能纪要任务）", from: s)
        }
      }
    }
  }

  func onSubtitleMessage(_ message: DingRtcSubtitleMessage) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.subtitleOn else { return }
      // 只显示原文（translate 翻译流本轮忽略）；sentenceEnd 定稿后整句保留到下一句覆盖。
      if message.translate { return }
      self.subtitleWaitTimer?.invalidate()
      self.subtitleWaitTimer = nil
      self.setSubtitleVisible(true, text: "\(message.userId)：\(message.subtitle)")
    }
  }

  func onLanguageListsUpdated() {
    NSLog("[F16 RTC Native] subtitle language lists updated")
  }
}

// MARK: - F16 v0.7 互动白板回调（RtcMeetingWindowBridge）
extension RtcMeetingWindowBridge: DingRtcEngineWhiteboardManagerDelegate {
  func onWhiteboardStart(_ whiteboardId: String, config cfg: DingRtcWbConfig) {
    // 频道内白板启动通知 (含远端发起)。本端 open 在 wb 对象 onJoinResult 成功后做。
    NSLog("[F16 RTC Native] whiteboard started id=\(whiteboardId)")
  }

  func onWhiteboardStop(_ whiteboardId: String) {
    DispatchQueue.main.async { [weak self] in
      NSLog("[F16 RTC Native] whiteboard stopped id=\(whiteboardId)")
      self?.teardownWhiteboard()
    }
  }

  func onWhiteboardServerStateChanged(_ state: DingRtcWbServerState, reason: Int32) {
    NSLog("[F16 RTC Native] whiteboard server state=\(state.rawValue) reason=\(reason)")
  }
}

// MARK: - F16 v0.7.4 讨论输入（S6: 空内容禁用发送箭头）
extension RtcMeetingWindowBridge: NSTextFieldDelegate {
  func controlTextDidChange(_ obj: Notification) {
    guard (obj.object as? NSTextField) === discussionInput else { return }
    updateDiscussionSendEnabled()
  }
}

// MARK: - F16 v0.7 白板对象事件（join 成功后才能 open）
extension RtcMeetingWindowBridge: DingRtcEngineWhiteboardDelegate {
  func onJoinResult(_ result: Int32, whiteboard whiteboardId: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      NSLog("[F16 RTC Native] whiteboard join result=\(result) id=\(whiteboardId)")
      guard result == 0 else {
        if let s = self.moreBtn { self.showInfoMenu("加入白板失败(\(result))", from: s) }
        self.teardownWhiteboard()
        return
      }
      guard let wb = self.whiteboardObj, let cv = self.whiteboardWindow?.contentView else { return }
      let rc = wb.open(cv)
      NSLog("[F16 RTC Native] whiteboard open rc=\(rc)")
      if rc != 0 {
        if let s = self.moreBtn { self.showInfoMenu("打开白板失败(\(rc))", from: s) }
        self.teardownWhiteboard()
      }
    }
  }
}
