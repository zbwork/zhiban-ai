// F18 桌面更新 · Windows native WinSparkle bridge（与 macOS Sparkle 同一 contract）。
//
//   - MethodChannel "cn.qkfintech.zhiban/update"（与 macOS 同名）
//   - 更新链路：WinSparkle 读 appcast + EdDSA(ed25519) 验签 + 下载 + 安装 + 重启
//
// 仅在 CMake 找到 WinSparkle SDK（WINSPARKLE_DIR）时编译并定义 HAVE_WINSPARKLE；
// 未找到时本文件不编入构建，runner 行为不变，运行期 update 通道为 MissingPlugin（未完成态）。

#ifndef RUNNER_WINSPARKLE_BRIDGE_H_
#define RUNNER_WINSPARKLE_BRIDGE_H_

#include <flutter/flutter_engine.h>

// 在 FlutterWindow::OnCreate 内、RegisterPlugins 之后调用一次（平台线程）。
// 注册 cn.qkfintech.zhiban/update。仅 HAVE_WINSPARKLE 下有真实实现。
void WinSparkleBridgeRegister(flutter::FlutterEngine* engine);

// 在 FlutterWindow::OnDestroy 调用：若已 init 则 win_sparkle_cleanup，避免退出期后台线程残留。
void WinSparkleBridgeCleanup();

#endif  // RUNNER_WINSPARKLE_BRIDGE_H_
