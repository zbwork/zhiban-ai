#include "fixture_bridge.cpp"

#include <filesystem>
#include <fstream>
#include <stdexcept>

namespace fs = std::filesystem;
fs::path probe_root;
DWORD platform_thread;

void Record(const char* event) {
  std::ofstream out(probe_root / "native-events.jsonl", std::ios::app);
  out << "{\"event\":\"" << event << "\",\"build\":\""
      << FLUTTER_VERSION_BUILD << "\",\"platformThread\":"
      << (GetCurrentThreadId() == platform_thread ? "true" : "false") << "}\n";
}

std::string Read(const fs::path& path) {
  std::ifstream input(path);
  return std::string(std::istreambuf_iterator<char>(input), {});
}

LRESULT CALLBACK FixtureWindowProc(HWND window, UINT message, WPARAM value, LPARAM param) {
  if (message == kUpdateEvent) {
    const char* names[] = {"cancelled", "failed", "notFound", "installerLaunched"};
    if (value < 4) Record(names[value]);
    return 0;
  }
  if (message == WM_TIMER) {
    const auto command_path = probe_root / "native-command";
    const auto command = Read(command_path);
    if (command.empty()) return 0;
    fs::remove(command_path);
    if (command == "quit") {
      PostQuitMessage(0);
      return 0;
    }
    const auto feed = Read(probe_root / "feed-url");
    if (!EnsureInitialized(feed)) {
      Record("busy");
      return 0;
    }
    g_update_in_progress = true;
    // Same-feed reentry must be rejected too, before it starts a second cycle.
    if (EnsureInitialized(feed)) {
      Record("failedBusyReentry");
      return 0;
    }
    if (command == "install") win_sparkle_check_update_with_ui_and_install();
    else win_sparkle_check_update_with_ui();
    return 0;
  }
  return DefWindowProcW(window, message, value, param);
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  probe_root = fs::absolute(argv[1]);
  platform_thread = GetCurrentThreadId();
  // This fixture never uses the production app's registry or identity.
  const auto registry = "Software\\EasyOUpdateVerification\\" + probe_root.filename().string();
  win_sparkle_set_registry_path(registry.c_str());
  win_sparkle_set_app_details(L"EasyO Update Verification", L"EasyOUpdateFixture", L"0.0.0");
  WNDCLASSW wc{};
  wc.lpfnWndProc = FixtureWindowProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"EasyOUpdateVerificationEvents";
  if (!RegisterClassW(&wc)) return 3;
  const auto window = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0,
                                    HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
  if (!window) return 4;
  g_event_window = window;
  SetTimer(window, 1, 100, nullptr);
  Record("started");
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  WinSparkleBridgeCleanup();
  return 0;
}
