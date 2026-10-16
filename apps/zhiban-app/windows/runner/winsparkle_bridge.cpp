// F18 桌面更新 · Windows native WinSparkle bridge 实现。
// 见 winsparkle_bridge.h 与 docs/features/F18-client-desktop-shell.md §6。

#include "winsparkle_bridge.h"

#ifndef HAVE_WINSPARKLE

// WinSparkle SDK 未配置：no-op。flutter_window.cpp 的调用点也在 HAVE_WINSPARKLE 下，
// 正常构建不会走到这里；保留以防本文件被单独编译。
void WinSparkleBridgeRegister(flutter::FlutterEngine* /*engine*/) {}
void WinSparkleBridgeCleanup() {}

#else

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <atomic>
#include <memory>
#include <string>
#include <variant>

#include <winsparkle.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Independent Windows update key, supplied from packaging/ed25519-public-key.txt.
// The private key remains on the Windows signing host.
constexpr char kEdDsaPublicKey[] = ZHIBAN_WINDOWS_UPDATE_PUBLIC_KEY;

constexpr char kDefaultAppcastUrl[] =
    "https://zb.qkfintech.cn/api/agent-bus/v1/app/appcast?platform=windows&channel=stable";

bool g_initialized = false;
std::atomic<bool> g_update_in_progress{false};
std::string g_appcast_url = kDefaultAppcastUrl;
std::shared_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::atomic<HWND> g_event_window{nullptr};
constexpr UINT kUpdateEvent = WM_APP + 18;
constexpr wchar_t kEventWindowClass[] = L"ZhibanUpdateEvents";

enum class UpdateEvent : WPARAM { cancelled, failed, notFound, installerLaunched };

// WinSparkle invokes callbacks on its worker threads. Only the platform thread
// may deliver Flutter messages; post a small enum to a message-only window.
void Emit(UpdateEvent event) {
  g_update_in_progress = false;
  if (const HWND window = g_event_window.load()) {
    PostMessageW(window, kUpdateEvent, static_cast<WPARAM>(event), 0);
  }
}

LRESULT CALLBACK UpdateWindowProc(HWND window, UINT message, WPARAM value,
                                 LPARAM param) {
  if (message == kUpdateEvent && g_channel) {
    const char* events[] = {"cancelled", "failed", "notFound", "installerLaunched"};
    if (value < 4) {
      g_channel->InvokeMethod("updateEvent", std::make_unique<EncodableValue>(
          EncodableMap{{EncodableValue("event"), EncodableValue(events[value])}}));
    }
    return 0;
  }
  return DefWindowProcW(window, message, value, param);
}

// 诊断日志：OutputDebugString 给 DebugView / VS「输出」窗口；stderr 给 flutter run 终端。
void Log(const char* msg) {
  OutputDebugStringA(msg);
  std::fputs(msg, stderr);
  std::fflush(stderr);
}

// WinSparkle 回调（均为 __cdecl 无参）：定位「有没有走到、判没判到更新、是否报错」。
void __cdecl OnDidFindUpdate() { Log("[WinSparkle] didFindUpdate\n"); }
void __cdecl OnDidNotFindUpdate() {
  Emit(UpdateEvent::notFound);
  Log("[WinSparkle] didNotFindUpdate (当前已是最新或版本不高于本地)\n");
}
void __cdecl OnUpdateError() {
  Emit(UpdateEvent::failed);
  Log("[WinSparkle] error (appcast 拉取/解析失败、网络或验签问题)\n");
}
void __cdecl OnUpdateDismissed() { Emit(UpdateEvent::cancelled); }
int __cdecl OnRunInstaller(const wchar_t*) {
  Emit(UpdateEvent::installerLaunched);
  return 0;  // The verified installer is still launched by WinSparkle.
}

// WinSparkle 的配置必须在 win_sparkle_init() 之前完成。
bool EnsureInitialized(const std::string& override_url) {
  if (g_update_in_progress) return false;
  if (g_initialized) {
    if (override_url.empty() || override_url == g_appcast_url) return true;
    // WinSparkle configuration is only supported before init. Reinitialize
    // after an idle cycle when switching from the remote feed to a local cache.
    win_sparkle_cleanup();
    g_initialized = false;
  }
  if (!override_url.empty()) {
    g_appcast_url = override_url;
  }
  win_sparkle_set_appcast_url(g_appcast_url.c_str());
  win_sparkle_set_eddsa_public_key(kEdDsaPublicKey);
  // Bus sparkle:version is an integer build, not the displayed ProductVersion.
  const auto build_version = std::to_wstring(FLUTTER_VERSION_BUILD);
  win_sparkle_set_app_build_version(build_version.c_str());
  // 关闭自动检查：避免 init 自带的定时检查；探测由我们显式调用。
  win_sparkle_set_automatic_check_for_updates(0);
  // 诊断回调，便于在 Windows 上定位问题。
  win_sparkle_set_did_find_update_callback(&OnDidFindUpdate);
  win_sparkle_set_did_not_find_update_callback(&OnDidNotFindUpdate);
  win_sparkle_set_error_callback(&OnUpdateError);
  win_sparkle_set_update_cancelled_callback(&OnUpdateDismissed);
  win_sparkle_set_update_dismissed_callback(&OnUpdateDismissed);
  win_sparkle_set_update_postponed_callback(&OnUpdateDismissed);
  win_sparkle_set_user_run_installer_callback(&OnRunInstaller);
  // Display version and app identity still come from Runner.rc VERSIONINFO.
  win_sparkle_init();
  Log("[WinSparkle] init done, appcast=");
  Log(g_appcast_url.c_str());
  Log("\n");
  g_initialized = true;
  return true;
}

// 从 method 参数里取可选的 feedUrl（覆盖默认 appcast）。
std::string ReadFeedUrlArg(const EncodableValue* args) {
  if (!args) {
    return std::string();
  }
  const auto* map = std::get_if<EncodableMap>(args);
  if (!map) {
    return std::string();
  }
  const auto it = map->find(EncodableValue("feedUrl"));
  if (it == map->end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

}  // namespace

void WinSparkleBridgeRegister(flutter::FlutterEngine* engine) {
  // 进程级单例：通道保活在静态变量里，注册一次。
  if (g_channel) {
    return;
  }

  auto* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(
              engine->GetRegistrarForPlugin("WinSparkleBridgePlugin"));
  if (!registrar) {
    return;
  }

  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = UpdateWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kEventWindowClass;
  RegisterClassW(&window_class);
  g_event_window = CreateWindowExW(0, kEventWindowClass, L"", 0, 0, 0, 0, 0,
                                 HWND_MESSAGE, nullptr, window_class.hInstance, nullptr);

  g_channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "cn.qkfintech.zhiban/update",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        const std::string feed_url = ReadFeedUrlArg(call.arguments());

        if (method == "checkForUpdates") {
          // 用户主动检查：弹 WinSparkle 进度 UI（无更新也提示「已是最新」）。
          if (!EnsureInitialized(feed_url)) {
            result->Success(EncodableValue(false));
            return;
          }
          g_update_in_progress = true;
          win_sparkle_check_update_with_ui();
          result->Success(EncodableValue(true));
        } else if (method == "checkForUpdatesSilently") {
          // 静默探测：无进度 UI；发现更新时 WinSparkle 自动弹出更新窗口。
          if (!EnsureInitialized(feed_url)) {
            result->Success(EncodableValue(false));
            return;
          }
          g_update_in_progress = true;
          win_sparkle_check_update_without_ui();
          result->Success(EncodableValue(true));
        } else if (method == "installUpdateInBackground") {
          if (!EnsureInitialized(feed_url)) {
            result->Success(EncodableValue(false));
            return;
          }
          g_update_in_progress = true;
          win_sparkle_check_update_with_ui_and_install();
          result->Success(EncodableValue(true));
        } else if (method == "getUpdateState") {
          result->Success(EncodableValue(EncodableMap{
              {EncodableValue("pendingInstall"), EncodableValue(false)},
              {EncodableValue("canCheckForUpdates"), EncodableValue(!g_update_in_progress.load())},
          }));
        } else if (method == "getUpdateFeedUrl") {
          result->Success(EncodableValue(g_appcast_url));
        } else {
          result->NotImplemented();
        }
      });

  // 仅初始化（设 appcast/公钥/回调）；检查时机由 Dart 统一驱动（启动 + 恢复），与 macOS 一致。
  Log("[WinSparkle] bridge registered\n");
  // The first check supplies its feed, which may be a restored local package.
}

void WinSparkleBridgeCleanup() {
  if (g_initialized) {
    win_sparkle_cleanup();
    g_initialized = false;
  }
  if (HWND window = g_event_window.exchange(nullptr)) DestroyWindow(window);
  g_channel.reset();
}

#endif  // HAVE_WINSPARKLE
