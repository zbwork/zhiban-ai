#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

#ifdef HAVE_DINGRTC
#include "dingrtc_bridge.h"  // F16 RTC: only compiled when CMake finds DingRTC Windows SDK
#endif

#ifdef HAVE_WINSPARKLE
#include "winsparkle_bridge.h"  // F18 Update: only compiled when CMake finds WinSparkle SDK
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() { desktop_network_.reset(); }

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_network_ = std::make_unique<DesktopNetworkBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  local_agent_lifecycle_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "nexwork/local_agent_lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
#ifdef HAVE_DINGRTC
  // F16 RTC: register easyo/rtc/methods + easyo/rtc/events (SDK available only).
  DingRtcBridgeRegister(flutter_controller_->engine());
#endif
#ifdef HAVE_WINSPARKLE
  // F18 Update: register cn.qkfintech.zhiban/update (WinSparkle available only).
  WinSparkleBridgeRegister(flutter_controller_->engine());
#endif
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
#ifdef HAVE_WINSPARKLE
  // F18 Update: stop WinSparkle background threads before teardown.
  WinSparkleBridgeCleanup();
#endif
  local_agent_lifecycle_.reset();
  desktop_network_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (desktop_network_ && desktop_network_->HandleMessage(message)) return 0;
  if (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND && local_agent_lifecycle_) {
    local_agent_lifecycle_->InvokeMethod("willSleep", nullptr);
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
