# DingRTC Windows SDK（本地放置，不入仓）

F16 RTC · Windows 端 `dingrtc_bridge.cpp` 需要 DingRTC Windows SDK 才能编入。
SDK 二进制（~60MB）**不提交到 git**（见 `apps/zhiban-app/.gitignore`），各开发机本地放一次。

## 放置步骤

1. 下载官方 SDK（3.9.0）：
   https://dingrtc.oss-cn-zhangjiakou.aliyuncs.com/sdk/windows/3.9.0/DingRTC_Windows_SDK_3_9_0.zip
2. 解压到本目录，使最终结构为：
   ```
   windows/runner/third_party/DingRTC_Windows_SDK_3_9_0/
     ├─ api/engine_interface.h   (及其它头文件)
     └─ lib/x64/DingRTC.lib      (及 DingRTC.dll 等运行时 DLL)
   ```
3. 在 `apps/zhiban-app` 下重新构建：
   ```powershell
   flutter clean
   flutter run -d windows
   ```
   CMake 会自动探测本目录（无需配环境变量），并打印
   `F16 RTC: ... RTC bridge ENABLED`。

## 路径优先级（windows/runner/CMakeLists.txt）

1. CMake cache 变量 `-DDINGRTC_WINDOWS_SDK_DIR=<dir>`
2. 环境变量 `DINGRTC_WINDOWS_SDK_DIR`
3. 本目录默认路径 `third_party/DingRTC_Windows_SDK_3_9_0`（推荐，免配置）

三者任一命中且含 `api/engine_interface.h` 即启用 RTC bridge；都没有则 `easyo/rtc/*` 为
`MissingPluginException`（未配置态）。
