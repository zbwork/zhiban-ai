// F16 RTC · Windows native DingRTC bridge 实现。见 dingrtc_bridge.h。
// 仅在 HAVE_DINGRTC（CMake 找到 DingRTC Windows SDK）下编译真实实现。
// 签名按 DingRTC Windows SDK 3.9.0 头文件核验。

#include "dingrtc_bridge.h"

#ifndef HAVE_DINGRTC

// 无 SDK：不注册任何 channel。easyo/rtc/* 在运行期为 MissingPlugin（未完成态、非目标）。
void DingRtcBridgeRegister(flutter::FlutterEngine* /*engine*/) {}

#else  // HAVE_DINGRTC

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>

// DingRTC Windows SDK（api/）。
#include "engine_interface.h"
#include "engine_rtm.h"
#include "engine_types.h"
#include "engine_device_manager.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// 平台线程投递：DingRTC 回调在 SDK 线程触发，EventSink 必须在平台线程调用。
constexpr UINT kEmitMessage = WM_APP + 0x5C;
// RTM session 跨线程投递：OnSessionCreate(SDK 线程) → 平台线程 JoinSession（与 leave/dispose 串行）。
constexpr UINT kRtmJoinMessage = WM_APP + 0x5D;
constexpr wchar_t kMsgWindowClass[] = L"EasyoRtcBridgeMsgWindow";
constexpr wchar_t kVideoWindowClass[] = L"EasyoRtcVideoOverlay";

// kRtmJoinMessage 的堆载荷：sessionId + 投递时的 RTM 代际（epoch）。平台线程只在代际
// 未变（投递后未发生 TeardownRtm）时才真正 JoinSession，否则丢弃（迟到/已 teardown）。
struct RtmJoinPayload {
  std::string session_id;
  uint64_t epoch;
};

std::string MapGetString(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(std::string(key)));
  if (it != m.end()) {
    if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  }
  return std::string();
}

bool MapGetBool(const EncodableMap& m, const char* key, bool fallback) {
  auto it = m.find(EncodableValue(std::string(key)));
  if (it != m.end()) {
    if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  }
  return fallback;
}

int NetworkLevel(ding::rtc::RtcEngineNetworkQuality up,
                 ding::rtc::RtcEngineNetworkQuality down) {
  int u = static_cast<int>(up);
  int d = static_cast<int>(down);
  if (u == 2 || d == 2) return 2;            // Disconnect
  if (u == 3 && d == 3) return 3;            // Unknown
  int worst = 0;                             // Good
  if (u != 3 && u > worst) worst = u;
  if (d != 3 && d > worst) worst = d;
  return worst;                              // 0 good / 1 poor
}

class DingRtcBridge {
 public:
  DingRtcBridge() : rtc_listener_(this), rtm_listener_(this), agent_listener_(this) {
    msg_window_ready_ = CreateMessageWindow();
  }

  void RegisterChannels(flutter::PluginRegistrarWindows* registrar) {
    auto* view = registrar->GetView();
    if (view) flutter_hwnd_ = view->GetNativeWindow();
    auto* messenger = registrar->messenger();
    method_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "easyo/rtc/methods",
        &flutter::StandardMethodCodec::GetInstance());
    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
          HandleMethodCall(call, std::move(result));
        });

    event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "easyo/rtc/events",
        &flutter::StandardMethodCodec::GetInstance());
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              event_sink_ = std::move(sink);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              event_sink_.reset();
              return nullptr;
            }));
  }

  // SDK 线程安全：堆分配 payload，PostMessage 到平台线程的 message-only 窗口。
  void Emit(EncodableMap payload) {
    if (!msg_hwnd_) return;
    auto* heap = new EncodableValue(std::move(payload));
    if (!::PostMessageW(msg_hwnd_, kEmitMessage, 0,
                        reinterpret_cast<LPARAM>(heap))) {
      delete heap;
    }
  }

  // 平台线程：真正下发到 Flutter。
  void DeliverEvent(EncodableValue* value) {
    if (event_sink_ && value) event_sink_->Success(*value);
  }

  // RTM session 建立（RtmEventListener，**SDK 线程**）。**不在此线程读写 rtm_/agent_session_id_，
  // 也不在此调用 JoinSession**——只把 sessionId + 当前代际堆分配后投到平台线程，真正入会在
  // WndProc(kRtmJoinMessage) 串行执行（与 TeardownRtm 同线程，消除竞态）。
  void OnRtmSessionCreate(const std::string& session_id) {
    if (!msg_hwnd_ || session_id.empty()) return;
    auto* payload = new RtmJoinPayload{
        session_id, rtm_epoch_.load(std::memory_order_relaxed)};
    if (!::PostMessageW(msg_hwnd_, kRtmJoinMessage, 0,
                        reinterpret_cast<LPARAM>(payload))) {
      delete payload;  // 投递失败/窗口已毁 → 立即释放，恰好一次（镜像 Emit）
    }
  }

 private:
  // ---- RtcEngineEventListener ----
  class RtcListener : public ding::rtc::RtcEngineEventListener {
   public:
    explicit RtcListener(DingRtcBridge* owner) : owner_(owner) {}
    void OnJoinChannelResult(int result, const char* channel, const char* userId,
                             int /*elapsed*/) override {
      if (result == 0) {
        owner_->Emit({{EncodableValue("type"), EncodableValue("joined")},
                      {EncodableValue("channelId"),
                       EncodableValue(channel ? std::string(channel) : std::string())},
                      {EncodableValue("userId"),
                       EncodableValue(userId ? std::string(userId) : std::string())}});
      } else {
        owner_->Emit({{EncodableValue("type"), EncodableValue("error")},
                      {EncodableValue("code"), EncodableValue(result)},
                      {EncodableValue("message"),
                       EncodableValue(std::string("onJoinChannelResult failed"))}});
      }
    }
    void OnLeaveChannelResult(int /*result*/,
                              ding::rtc::RtcEngineStats /*stats*/) override {
      owner_->Emit({{EncodableValue("type"), EncodableValue("left")}});
    }
    void OnRemoteUserOnLineNotify(const char* uid, int /*elapsed*/) override {
      if (uid && *uid) {
        owner_->Emit({{EncodableValue("type"), EncodableValue("remoteUserJoined")},
                      {EncodableValue("userId"), EncodableValue(std::string(uid))}});
      }
    }
    void OnRemoteUserOffLineNotify(
        const char* uid, ding::rtc::RtcEngineUserOfflineReason /*reason*/) override {
      if (uid && *uid) {
        owner_->Emit({{EncodableValue("type"), EncodableValue("remoteUserLeft")},
                      {EncodableValue("userId"), EncodableValue(std::string(uid))}});
      }
    }
    void OnNetworkQualityChanged(
        const char* uid, ding::rtc::RtcEngineNetworkQuality upQuality,
        ding::rtc::RtcEngineNetworkQuality downQuality) override {
      if (uid && *uid) return;  // 仅上报本端（self uid 为空）
      owner_->Emit({{EncodableValue("type"), EncodableValue("networkQuality")},
                    {EncodableValue("level"),
                     EncodableValue(NetworkLevel(upQuality, downQuality))}});
    }
    void OnOccurError(int error, const char* msg) override {
      owner_->Emit({{EncodableValue("type"), EncodableValue("error")},
                    {EncodableValue("code"), EncodableValue(error)},
                    {EncodableValue("message"),
                     EncodableValue(msg ? std::string(msg) : std::string("error"))}});
    }
    void OnRemoteTrackAvailableNotify(
        const char* uid, ding::rtc::RtcEngineAudioTrack /*audioTrack*/,
        ding::rtc::RtcEngineVideoTrack videoTrack) override {
      if (!uid || !*uid) return;
      bool screenAvailable =
          (static_cast<int>(videoTrack) &
           static_cast<int>(ding::rtc::RtcEngineVideoTrackScreen)) != 0;
      bool cameraAvailable =
          (static_cast<int>(videoTrack) &
           static_cast<int>(ding::rtc::RtcEngineVideoTrackCamera)) != 0;
      owner_->Emit(
          {{EncodableValue("type"), EncodableValue("screenShare")},
           {EncodableValue("scope"), EncodableValue("remote")},
           {EncodableValue("active"), EncodableValue(screenAvailable)},
           {EncodableValue("userId"), EncodableValue(std::string(uid))}});
      owner_->Emit(
          {{EncodableValue("type"), EncodableValue("remoteVideo")},
           {EncodableValue("userId"), EncodableValue(std::string(uid))},
           {EncodableValue("enabled"), EncodableValue(cameraAvailable)}});
    }
    void OnScreenSharePublishStateChanged(
        ding::rtc::RtcEnginePublishState /*oldState*/,
        ding::rtc::RtcEnginePublishState newState,
        int /*elapseSinceLastState*/, const char* /*channel*/) override {
      bool active = (static_cast<int>(newState) == 3);  // RtcEngineStatsPublished
      owner_->screen_sharing_ = active;
      owner_->Emit(
          {{EncodableValue("type"), EncodableValue("screenShare")},
           {EncodableValue("scope"), EncodableValue("local")},
           {EncodableValue("active"), EncodableValue(active)}});
    }
    void OnScreenShareSubscribeStateChanged(
        const char* uid, ding::rtc::RtcEngineSubscribeState /*oldState*/,
        ding::rtc::RtcEngineSubscribeState newState,
        int /*elapseSinceLastState*/, const char* /*channel*/) override {
      bool active = (static_cast<int>(newState) >= 2);  // Subscribing/Subscribed
      owner_->Emit(
          {{EncodableValue("type"), EncodableValue("screenShare")},
           {EncodableValue("scope"), EncodableValue("remote")},
           {EncodableValue("active"), EncodableValue(active)},
           {EncodableValue("userId"),
            EncodableValue(uid ? std::string(uid) : std::string())}});
    }

   private:
    DingRtcBridge* owner_;
  };

  // ---- RtmEventListener（onSessionCreate → joinSession，对齐其它平台）----
  class RtmListener : public ding::rtc::RtmEventListener {
   public:
    explicit RtmListener(DingRtcBridge* owner) : owner_(owner) {}
    void OnSessionCreate(const ding::rtc::String& sessionId) override {
      owner_->OnRtmSessionCreate(sessionId.c_str() ? std::string(sessionId.c_str())
                                                   : std::string());
    }

   private:
    DingRtcBridge* owner_;
  };

  // ---- RtmAgentEventListener（agentReady / agentState / agentTranscription）----
  class AgentListener : public ding::rtc::RtmAgentEventListener {
   public:
    explicit AgentListener(DingRtcBridge* owner) : owner_(owner) {}
    void OnAgentUserReady(const ding::rtc::String& sessionId,
                          const ding::rtc::String& agentId) override {
      owner_->Emit({{EncodableValue("type"), EncodableValue("agentReady")},
                    {EncodableValue("sessionId"), EncodableValue(Str(sessionId))},
                    {EncodableValue("agentId"), EncodableValue(Str(agentId))}});
    }
    void OnAgentStateChanged(const ding::rtc::String& /*sessionId*/,
                             const ding::rtc::String& agentId,
                             ding::rtc::AgentState state) override {
      owner_->Emit({{EncodableValue("type"), EncodableValue("agentState")},
                    {EncodableValue("agentId"), EncodableValue(Str(agentId))},
                    {EncodableValue("state"), EncodableValue(static_cast<int>(state))}});
    }
    void OnTranscriptionMessage(const ding::rtc::String& /*sessionId*/,
                                const ding::rtc::String& /*agentId*/,
                                const ding::rtc::TranscriptionData& data) override {
      const bool is_user =
          data.speakerType == ding::rtc::RtmAgentSpeakerType::User;
      owner_->Emit(
          {{EncodableValue("type"), EncodableValue("agentTranscription")},
           {EncodableValue("speaker"),
            EncodableValue(std::string(is_user ? "user" : "agent"))},
           {EncodableValue("roundId"), EncodableValue(data.roundId)},
           {EncodableValue("end"), EncodableValue(data.end)},
           {EncodableValue("text"), EncodableValue(Str(data.text))},
           {EncodableValue("reasoning"), EncodableValue(Str(data.reasoningText))},
           {EncodableValue("beginTime"),
            EncodableValue(static_cast<int64_t>(data.beginTime))}});
    }

   private:
    static std::string Str(const ding::rtc::String& s) {
      return s.c_str() ? std::string(s.c_str()) : std::string();
    }
    DingRtcBridge* owner_;
  };

  // ---- 方法分发（平台线程）----
  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();
    const auto* args = std::get_if<EncodableMap>(call.arguments());

    if (method == "initialize") {
      // 事件投递依赖 message-only 窗口（Emit→PostMessage→DeliverEvent）。窗口创建失败时
      // EventChannel 将永远收不到 joined/left/error/... → 明确报错，**不假装 initialize 成功**。
      if (!msg_window_ready_ || !msg_hwnd_) {
        result->Error("event_window_unavailable",
                      "failed to create RTC event message window");
        return;
      }
      if (!engine_) {
        engine_ = ding::rtc::RtcEngine::Create("");
        if (engine_) engine_->SetEngineEventListener(&rtc_listener_);
      }
      result->Success();
      return;
    }
    if (method == "joinChannel") {
      HandleJoin(args, std::move(result));
      return;
    }
    if (method == "setMicrophoneMuted") {
      bool muted = args ? MapGetBool(*args, "muted", false) : false;
      if (engine_) engine_->MuteLocalAudio(muted);
      result->Success();
      return;
    }
    if (method == "setCameraEnabled") {
      if (!engine_) {
        result->Error("not_joined", "engine not ready");
        return;
      }
      bool enabled = args ? MapGetBool(*args, "enabled", false) : false;
      int rc1 = engine_->EnableLocalVideo(enabled);
      int rc2 = engine_->PublishLocalVideoStream(enabled);
      // 无 Windows 视频 view（本轮未实现 PlatformView）→ 不调用 StartPreview。
      result->Success(EncodableValue(rc1 != 0 ? rc1 : rc2));
      return;
    }
    if (method == "leaveChannel") {
      TeardownRtm();
      // engine_ 为空（未 initialize / 已 dispose）→ 视为已离开，返回 0（幂等，对齐 Android handleLeave）。
      // 这样上层不会误把"重复离开"当 rc!=0 失败去触发 dispose+recreate。
      DetachLocalOverlay();
      DetachAllOverlays();
      if (engine_ && screen_sharing_) engine_->StopScreenShare();
      screen_sharing_ = false;
      int rc = engine_ ? engine_->LeaveChannel() : 0;
      result->Success(EncodableValue(rc));
      return;
    }
    if (method == "listDevices") {
      HandleListDevices(args, std::move(result));
      return;
    }
    if (method == "selectDevice") {
      HandleSelectDevice(args, std::move(result));
      return;
    }
    if (method == "listScreenShareSources") {
      HandleListScreenShareSources(std::move(result));
      return;
    }
    if (method == "startScreenShare") {
      HandleStartScreenShare(args, std::move(result));
      return;
    }
    if (method == "stopScreenShare") {
      if (engine_) engine_->StopScreenShare();
      screen_sharing_ = false;
      result->Success(EncodableValue(0));
      return;
    }
    if (method == "attachLocalVideo") {
      HandleAttachLocalVideo(args, std::move(result));
      return;
    }
    if (method == "detachLocalVideo") {
      HandleDetachLocalVideo(std::move(result));
      return;
    }
    if (method == "attachRemoteVideo") {
      HandleAttachRemoteVideo(args, std::move(result));
      return;
    }
    if (method == "detachRemoteVideo") {
      HandleDetachRemoteVideo(args, std::move(result));
      return;
    }
    if (method == "updateVideoRect") {
      HandleUpdateVideoRect(args, std::move(result));
      return;
    }
    if (method == "updateLocalVideoRect") {
      HandleUpdateLocalVideoRect(args, std::move(result));
      return;
    }
    if (method == "dispose") {
      TeardownRtm();
      DetachLocalOverlay();
      DetachAllOverlays();
      screen_sharing_ = false;
      screen_source_types_.clear();
      if (engine_) {
        engine_->SetEngineEventListener(nullptr);
        ding::rtc::RtcEngine::Destroy(engine_);
        engine_ = nullptr;
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  void HandleListScreenShareSources(
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!engine_) {
      result->Success(EncodableValue(EncodableList()));
      return;
    }
    EncodableList out;
    screen_source_types_.clear();
    struct Kind { ding::rtc::RtcEngineScreenShareType type; const char* name; };
    Kind kinds[] = {
        {ding::rtc::RtcEngineScreenShareDesktop, "screen"},
        {ding::rtc::RtcEngineScreenShareWindow, "window"},
    };
    for (auto& k : kinds) {
      auto* list = engine_->GetScreenShareSourceInfo(k.type);
      if (!list) continue;
      for (unsigned int i = 0; i < list->GetCount(); ++i) {
        auto info = list->GetDeviceInfo(i);
        std::string id = info.deviceID.c_str() ? info.deviceID.c_str() : "";
        std::string name = info.deviceName.c_str() ? info.deviceName.c_str() : "";
        if (!id.empty()) {
          screen_source_types_[id] = k.type;
          out.push_back(EncodableValue(EncodableMap{
              {EncodableValue("id"), EncodableValue(id)},
              {EncodableValue("name"), EncodableValue(name)},
              {EncodableValue("kind"), EncodableValue(std::string(k.name))},
          }));
        }
      }
      list->Release();
    }
    result->Success(EncodableValue(std::move(out)));
  }

  void HandleStartScreenShare(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!engine_) {
      result->Error("not_initialized", "call initialize first");
      return;
    }
    std::string source_id = args ? MapGetString(*args, "sourceId") : "";
    ding::rtc::RtcEngineScreenShareConfig config{};
    int rc = -1;
    if (!source_id.empty()) {
      auto it = screen_source_types_.find(source_id);
      auto type = (it != screen_source_types_.end())
                      ? it->second
                      : ding::rtc::RtcEngineScreenShareDesktop;
      if (type == ding::rtc::RtcEngineScreenShareWindow) {
        rc = engine_->StartScreenShareByWindowId(source_id.c_str(), config);
      } else {
        rc = engine_->StartScreenShareByDesktopId(source_id.c_str(), config);
      }
    } else {
      auto* desktops = engine_->GetScreenShareSourceInfo(
          ding::rtc::RtcEngineScreenShareDesktop);
      if (desktops && desktops->GetCount() > 0) {
        auto info = desktops->GetDeviceInfo(0);
        std::string first_id =
            info.deviceID.c_str() ? info.deviceID.c_str() : "";
        if (!first_id.empty()) {
          rc = engine_->StartScreenShareByDesktopId(first_id.c_str(), config);
        }
      }
      if (desktops) desktops->Release();
    }
    if (rc == 0) screen_sharing_ = true;
    result->Success(EncodableValue(rc));
  }

  void HandleJoin(const EncodableMap* args,
                  std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!engine_) {
      result->Error("not_initialized", "call initialize first");
      return;
    }
    if (!args) {
      result->Error("bad_args", "joinChannel missing arguments");
      return;
    }
    std::string app_id = MapGetString(*args, "appId");
    std::string channel_id = MapGetString(*args, "channelId");
    std::string user_id = MapGetString(*args, "userId");
    std::string token = MapGetString(*args, "token");
    std::string gslb = MapGetString(*args, "gslbServer");
    if (app_id.empty() || channel_id.empty() || user_id.empty() || token.empty()) {
      result->Error("bad_args", "joinChannel missing appId/channelId/userId/token");
      return;
    }
    bool video = MapGetBool(*args, "video", false);

    // auth 字符串生命周期：无悬垂风险，无需把入参缓存成 bridge 成员。
    // 头文件确认 RtcEngineAuthInfo 的 5 个字段均为 ding::rtc::String（engine_types.h:47-58），
    // 而 String 是深拷贝值类型（engine_utils.h:15-37：copy ctor :19 / operator=(const char*) :21 /
    // 析构 :24 / 私有 char* data :37）。因此 `auth.appId = app_id.c_str()` 走 String::operator=(const char*)，
    // 把 C 串拷进 String 自有缓冲，与局部 std::string 解耦。
    // JoinChannel(const RtcEngineAuthInfo&, ...)（engine_interface.h:1110）只在**同步调用期间**读取 authInfo
    // （入会结果才异步经 OnJoinChannelResult 回调，SDK 不会延后持有 authInfo 引用）；本地 auth 活到
    // 同步的 JoinChannel(...) 返回之后，故 HandleJoin 退出时局部串析构是安全的。
    ding::rtc::RtcEngineAuthInfo auth;
    auth.appId = app_id.c_str();
    auth.channelId = channel_id.c_str();
    auth.userId = user_id.c_str();
    auth.token = token.c_str();
    if (!gslb.empty()) auth.gslbServer = gslb.c_str();

    // 音频媒体：发布本地音频 + 订阅远端音频（Windows 桌面录制设备自动采集）。
    engine_->PublishLocalAudioStream(true);
    engine_->SubscribeAllRemoteAudioStreams(true);
    int video_rc = 0;
    if (video) {
      int a = engine_->EnableLocalVideo(true);
      int b = engine_->PublishLocalVideoStream(true);
      int c = engine_->SubscribeAllRemoteVideoStreams(true);
      video_rc = a != 0 ? a : (b != 0 ? b : c);
    }
    SetupRtm();
    int join_rc = engine_->JoinChannel(auth, nullptr);
    int rc = join_rc != 0 ? join_rc : video_rc;
    result->Success(EncodableValue(rc));  // rc!=0 → Dart 走 join-fail 清理，不吞返回码。
  }

  void HandleListDevices(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    std::string kind = args ? MapGetString(*args, "kind") : std::string();
    EncodableList out;
    if (engine_) {
      if (kind == "camera") {
        auto* vm = engine_->GetVideoDeviceManager();
        if (vm) {
          std::string cur = StrOf(vm->GetCurrentCameraID());
          AppendDevices(out, vm->GetCameraList(), kind, cur);
        }
      } else if (kind == "microphone") {
        auto* am = engine_->GetAudioDeviceManager();
        if (am) {
          std::string cur = StrOf(am->GetCurrentRecordingDeviceId());
          AppendDevices(out, am->GetRecordingDeviceList(), kind, cur);
        }
      } else if (kind == "speaker") {
        auto* am = engine_->GetAudioDeviceManager();
        if (am) {
          std::string cur = StrOf(am->GetCurrentPlayoutDeviceId());
          AppendDevices(out, am->GetPlayoutDeviceList(), kind, cur);
        }
      }
    }
    result->Success(EncodableValue(out));  // 未入会/无设备 → 空列表（合法，非 MissingPlugin）。
  }

  void HandleSelectDevice(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!engine_ || !args) {
      result->Success(EncodableValue(-1));
      return;
    }
    std::string kind = MapGetString(*args, "kind");
    std::string device_id = MapGetString(*args, "deviceId");
    int rc = -1;
    if (kind == "camera") {
      auto* vm = engine_->GetVideoDeviceManager();
      if (vm) rc = vm->SetCurrentCameraID(device_id.c_str());
    } else if (kind == "microphone") {
      auto* am = engine_->GetAudioDeviceManager();
      if (am) rc = am->SetCurrentRecordingDeviceId(device_id.c_str());
    } else if (kind == "speaker") {
      auto* am = engine_->GetAudioDeviceManager();
      if (am) rc = am->SetCurrentPlayoutDeviceId(device_id.c_str());
    }
    result->Success(EncodableValue(rc));  // rc!=0 → Dart 视为切换失败（回读由 SDK 决定）。
  }

  static std::string StrOf(const ding::rtc::String& s) {
    return s.c_str() ? std::string(s.c_str()) : std::string();
  }

  void AppendDevices(EncodableList& out, ding::rtc::RtcEngineDeviceInfoList* list,
                     const std::string& kind, const std::string& current_id) {
    if (!list) return;
    unsigned int count = list->GetCount();
    for (unsigned int i = 0; i < count; ++i) {
      ding::rtc::RtcEngineDeviceInfo info = list->GetDeviceInfo(i);
      std::string id = StrOf(info.deviceID);
      std::string name = StrOf(info.deviceName);
      out.push_back(EncodableValue(EncodableMap{
          {EncodableValue("id"), EncodableValue(id)},
          {EncodableValue("name"), EncodableValue(name.empty() ? id : name)},
          {EncodableValue("kind"), EncodableValue(kind)},
          {EncodableValue("is_current"),
           EncodableValue(!id.empty() && id == current_id)}}));
    }
    list->Release();
  }

  void SetupRtm() {
    if (!engine_) return;
    rtm_ = engine_->GetRtmClient();
    if (!rtm_) return;
    rtm_->SetListener(&rtm_listener_);
    agent_ = rtm_->GetAgentClient();
    if (agent_) agent_->SetListener(&agent_listener_);
  }

  void TeardownRtm() {
    // 代际自增：使所有「在飞」的 kRtmJoinMessage 失配 → 平台线程直接丢弃，不再 JoinSession
    // （即便重新入会后 GetRtmClient 返回同一 RtmClient*，也不会误把旧 session 入到新连接）。
    rtm_epoch_.fetch_add(1, std::memory_order_relaxed);
    if (rtm_) {
      if (!agent_session_id_.empty()) {
        rtm_->LeaveSession(ding::rtc::String(agent_session_id_.c_str()));
      }
      rtm_->SetListener(nullptr);
    }
    if (agent_) agent_->SetListener(nullptr);
    rtm_ = nullptr;
    agent_ = nullptr;
    agent_session_id_.clear();
  }

  // ---- message-only 窗口（平台线程投递）----
  // 返回 true 表示窗口创建成功；失败则 Emit 无处投递、EventChannel 收不到事件，
  // initialize 会据此返回 event_window_unavailable（不假装成功）。
  bool CreateMessageWindow() {
    HINSTANCE hinst = ::GetModuleHandleW(nullptr);
    WNDCLASSW wc = {};
    wc.lpfnWndProc = &DingRtcBridge::WndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = kMsgWindowClass;
    ::RegisterClassW(&wc);  // 重复注册返回 0（类已存在），不影响后续 CreateWindow，忽略。
    msg_hwnd_ = ::CreateWindowExW(0, kMsgWindowClass, L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr, hinst, this);
    return msg_hwnd_ != nullptr;
  }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam) {
    if (msg == WM_CREATE) {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
      return 0;
    }
    if (msg == kEmitMessage) {
      auto* self = reinterpret_cast<DingRtcBridge*>(
          ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      auto* value = reinterpret_cast<EncodableValue*>(lparam);
      if (self) self->DeliverEvent(value);
      delete value;
      return 0;
    }
    if (msg == kRtmJoinMessage) {
      auto* self = reinterpret_cast<DingRtcBridge*>(
          ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      auto* payload = reinterpret_cast<RtmJoinPayload*>(lparam);
      // 平台线程：与 TeardownRtm 同线程串行。三重闸——rtm_ 仍在 + sessionId 非空 +
      // 代际未变（投递后未发生 teardown）才入会；否则丢弃（迟到/已 teardown 的消息不再 JoinSession）。
      if (self && payload && self->rtm_ && !payload->session_id.empty() &&
          payload->epoch == self->rtm_epoch_.load(std::memory_order_relaxed)) {
        self->agent_session_id_ = payload->session_id;
        self->rtm_->JoinSession(
            ding::rtc::String(payload->session_id.c_str()));
      }
      delete payload;  // 无论是否入会，恰好释放一次（镜像 kEmitMessage 的 delete value）
      return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  // ---- Video overlay HWND management ----
  struct VideoOverlay {
    HWND hwnd = nullptr;
    std::string uid;
    ding::rtc::RtcEngineVideoTrack track =
        ding::rtc::RtcEngineVideoTrackScreen;
  };

  std::string VideoKey(const std::string& uid,
                       ding::rtc::RtcEngineVideoTrack track) {
    return uid + (track == ding::rtc::RtcEngineVideoTrackScreen ? ":screen"
                                                                 : ":camera");
  }

  void EnsureClipChildren() {
    if (!flutter_hwnd_) return;
    LONG_PTR style = ::GetWindowLongPtrW(flutter_hwnd_, GWL_STYLE);
    if (!(style & WS_CLIPCHILDREN)) {
      ::SetWindowLongPtrW(flutter_hwnd_, GWL_STYLE, style | WS_CLIPCHILDREN);
    }
  }

  static LRESULT CALLBACK VideoWndProc(HWND hwnd, UINT msg, WPARAM wp,
                                       LPARAM lp) {
    if (msg == WM_ERASEBKGND) return 1;
    return ::DefWindowProcW(hwnd, msg, wp, lp);
  }

  bool EnsureVideoWindowClass() {
    static bool registered = false;
    if (registered) return true;
    WNDCLASSW wc = {};
    wc.lpfnWndProc = &DingRtcBridge::VideoWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kVideoWindowClass;
    wc.hbrBackground = reinterpret_cast<HBRUSH>(
        ::GetStockObject(BLACK_BRUSH));
    registered = ::RegisterClassW(&wc) != 0;
    return registered;
  }

  void HandleAttachLocalVideo(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!engine_ || !args || !flutter_hwnd_) {
      result->Error("not_ready", "engine or flutter window not available");
      return;
    }
    double left = 0, top = 0, width = 320, height = 240;
    {
      auto it = args->find(EncodableValue(std::string("left")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) left = *d;
      }
      it = args->find(EncodableValue(std::string("top")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) top = *d;
      }
      it = args->find(EncodableValue(std::string("width")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) width = *d;
      }
      it = args->find(EncodableValue(std::string("height")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) height = *d;
      }
    }
    DetachLocalOverlay();
    if (!EnsureVideoWindowClass()) {
      result->Error("window_class_failed", "cannot register video window class");
      return;
    }
    EnsureClipChildren();
    HWND child = ::CreateWindowExW(
        0, kVideoWindowClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
        static_cast<int>(left), static_cast<int>(top),
        static_cast<int>(width), static_cast<int>(height),
        flutter_hwnd_, nullptr, ::GetModuleHandleW(nullptr), nullptr);
    if (!child) {
      result->Error("create_window_failed", "CreateWindowEx returned null");
      return;
    }
    ding::rtc::RtcEngineVideoCanvas canvas{};
    canvas.displayView = reinterpret_cast<void*>(child);
    canvas.renderMode =
        ding::rtc::RtcEngineRenderMode::RtcEngineRenderModeAuto;
    engine_->EnableLocalVideo(true);
    int rc = engine_->SetLocalViewConfig(canvas,
                                         ding::rtc::RtcEngineVideoTrackCamera);
    if (rc == 0) engine_->StartPreview();
    local_video_hwnd_ = child;
    result->Success(EncodableValue(rc));
  }

  void HandleDetachLocalVideo(
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    DetachLocalOverlay();
    result->Success();
  }

  void DetachLocalOverlay() {
    if (local_video_hwnd_) {
      if (engine_) {
        ding::rtc::RtcEngineVideoCanvas canvas{};
        canvas.displayView = nullptr;
        engine_->SetLocalViewConfig(canvas,
                                    ding::rtc::RtcEngineVideoTrackCamera);
        engine_->StopPreview();
      }
      ::DestroyWindow(local_video_hwnd_);
      local_video_hwnd_ = nullptr;
    }
  }

  void HandleAttachRemoteVideo(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!engine_ || !args || !flutter_hwnd_) {
      result->Error("not_ready", "engine or flutter window not available");
      return;
    }
    std::string uid = MapGetString(*args, "uid");
    std::string track_str = MapGetString(*args, "track");
    auto track = (track_str == "camera")
                     ? ding::rtc::RtcEngineVideoTrackCamera
                     : ding::rtc::RtcEngineVideoTrackScreen;
    double left = 0, top = 0, width = 320, height = 240;
    {
      auto it = args->find(EncodableValue(std::string("left")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) left = *d;
      }
      it = args->find(EncodableValue(std::string("top")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) top = *d;
      }
      it = args->find(EncodableValue(std::string("width")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) width = *d;
      }
      it = args->find(EncodableValue(std::string("height")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) height = *d;
      }
    }
    auto key = VideoKey(uid, track);
    DetachOverlay(key);
    if (!EnsureVideoWindowClass()) {
      result->Error("window_class_failed", "cannot register video window class");
      return;
    }
    EnsureClipChildren();
    HWND child = ::CreateWindowExW(
        0, kVideoWindowClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
        static_cast<int>(left), static_cast<int>(top),
        static_cast<int>(width), static_cast<int>(height),
        flutter_hwnd_, nullptr, ::GetModuleHandleW(nullptr), nullptr);
    if (!child) {
      result->Error("create_window_failed", "CreateWindowEx returned null");
      return;
    }
    ding::rtc::RtcEngineVideoCanvas canvas{};
    canvas.displayView = reinterpret_cast<void*>(child);
    canvas.renderMode =
        ding::rtc::RtcEngineRenderMode::RtcEngineRenderModeAuto;
    int rc = engine_->SetRemoteViewConfig(canvas, uid.c_str(), track);
    video_overlays_[key] = VideoOverlay{child, uid, track};
    result->Success(EncodableValue(rc));
  }

  void HandleDetachRemoteVideo(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!args) {
      result->Error("bad_args", "missing arguments");
      return;
    }
    std::string uid = MapGetString(*args, "uid");
    std::string track_str = MapGetString(*args, "track");
    auto track = (track_str == "camera")
                     ? ding::rtc::RtcEngineVideoTrackCamera
                     : ding::rtc::RtcEngineVideoTrackScreen;
    DetachOverlay(VideoKey(uid, track));
    result->Success();
  }

  void HandleUpdateVideoRect(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!args) {
      result->Error("bad_args", "missing arguments");
      return;
    }
    std::string uid = MapGetString(*args, "uid");
    std::string track_str = MapGetString(*args, "track");
    auto track = (track_str == "camera")
                     ? ding::rtc::RtcEngineVideoTrackCamera
                     : ding::rtc::RtcEngineVideoTrackScreen;
    auto key = VideoKey(uid, track);
    auto it = video_overlays_.find(key);
    if (it == video_overlays_.end() || !it->second.hwnd) {
      result->Success();
      return;
    }
    double left = 0, top = 0, width = 320, height = 240;
    {
      auto ait = args->find(EncodableValue(std::string("left")));
      if (ait != args->end()) {
        if (auto* d = std::get_if<double>(&ait->second)) left = *d;
      }
      ait = args->find(EncodableValue(std::string("top")));
      if (ait != args->end()) {
        if (auto* d = std::get_if<double>(&ait->second)) top = *d;
      }
      ait = args->find(EncodableValue(std::string("width")));
      if (ait != args->end()) {
        if (auto* d = std::get_if<double>(&ait->second)) width = *d;
      }
      ait = args->find(EncodableValue(std::string("height")));
      if (ait != args->end()) {
        if (auto* d = std::get_if<double>(&ait->second)) height = *d;
      }
    }
    ::MoveWindow(it->second.hwnd, static_cast<int>(left),
                 static_cast<int>(top), static_cast<int>(width),
                 static_cast<int>(height), FALSE);
    result->Success();
  }

  void HandleUpdateLocalVideoRect(
      const EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!args || !local_video_hwnd_) {
      result->Success();
      return;
    }
    double left = 0, top = 0, width = 320, height = 240;
    {
      auto it = args->find(EncodableValue(std::string("left")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) left = *d;
      }
      it = args->find(EncodableValue(std::string("top")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) top = *d;
      }
      it = args->find(EncodableValue(std::string("width")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) width = *d;
      }
      it = args->find(EncodableValue(std::string("height")));
      if (it != args->end()) {
        if (auto* d = std::get_if<double>(&it->second)) height = *d;
      }
    }
    ::MoveWindow(local_video_hwnd_, static_cast<int>(left),
                 static_cast<int>(top), static_cast<int>(width),
                 static_cast<int>(height), FALSE);
    result->Success();
  }

  void DetachOverlay(const std::string& key) {
    auto it = video_overlays_.find(key);
    if (it == video_overlays_.end()) return;
    auto& overlay = it->second;
    if (engine_ && overlay.hwnd) {
      ding::rtc::RtcEngineVideoCanvas canvas{};
      canvas.displayView = nullptr;
      engine_->SetRemoteViewConfig(canvas, overlay.uid.c_str(), overlay.track);
    }
    if (overlay.hwnd) ::DestroyWindow(overlay.hwnd);
    video_overlays_.erase(it);
  }

  void DetachAllOverlays() {
    for (auto& [key, overlay] : video_overlays_) {
      if (engine_ && overlay.hwnd) {
        ding::rtc::RtcEngineVideoCanvas canvas{};
        canvas.displayView = nullptr;
        engine_->SetRemoteViewConfig(canvas, overlay.uid.c_str(),
                                     overlay.track);
      }
      if (overlay.hwnd) ::DestroyWindow(overlay.hwnd);
    }
    video_overlays_.clear();
  }

  ding::rtc::RtcEngine* engine_ = nullptr;
  ding::rtc::RtmClient* rtm_ = nullptr;        // 由 engine 持有，不 delete
  ding::rtc::RtmAgentClient* agent_ = nullptr;  // 由 rtm 持有，不 delete
  std::atomic<bool> screen_sharing_{false};
  std::unordered_map<std::string, ding::rtc::RtcEngineScreenShareType>
      screen_source_types_;
  std::unordered_map<std::string, VideoOverlay> video_overlays_;
  std::string agent_session_id_;  // 仅平台线程读写（WndProc / TeardownRtm）
  std::atomic<uint64_t> rtm_epoch_{0};

  RtcListener rtc_listener_;
  RtmListener rtm_listener_;
  AgentListener agent_listener_;

  HWND msg_hwnd_ = nullptr;
  HWND flutter_hwnd_ = nullptr;
  HWND local_video_hwnd_ = nullptr;
  bool msg_window_ready_ = false;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
};

}  // namespace

void DingRtcBridgeRegister(flutter::FlutterEngine* engine) {
  static DingRtcBridge* g_bridge = nullptr;
  if (g_bridge) return;
  auto* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(
              engine->GetRegistrarForPlugin("DingRtcBridgePlugin"));
  if (!registrar) return;
  g_bridge = new DingRtcBridge();
  g_bridge->RegisterChannels(registrar);
}

#endif  // HAVE_DINGRTC
