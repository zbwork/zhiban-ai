// F16 RTC · Windows native DingRTC bridge（与 macOS/Android/iOS 同一 contract）。
//
//   - MethodChannel "easyo/rtc/methods"
//   - EventChannel  "easyo/rtc/events"
//   - 视频渲染：HWND child-window overlay（SetRemoteViewConfig + WS_CHILD 子窗口）
//
// 仅在 CMake 找到 DingRTC Windows SDK（DINGRTC_WINDOWS_SDK_DIR）时编译并定义 HAVE_DINGRTC；
// 未找到时本文件不编入构建，runner 行为不变，运行期 easyo/rtc/* 为 MissingPlugin（未完成态，非目标）。

#ifndef RUNNER_DINGRTC_BRIDGE_H_
#define RUNNER_DINGRTC_BRIDGE_H_

#include <flutter/flutter_engine.h>

// 在 FlutterWindow::OnCreate 内、RegisterPlugins 之后调用一次（平台线程）。
// 注册 easyo/rtc/methods + easyo/rtc/events。仅 HAVE_DINGRTC 下有真实实现。
void DingRtcBridgeRegister(flutter::FlutterEngine* engine);

#endif  // RUNNER_DINGRTC_BRIDGE_H_
