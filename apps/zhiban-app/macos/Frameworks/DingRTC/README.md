# DingRTC macOS SDK (vendored, 本地不入库)

F16 Phase 1 人↔人音频通话用的阿里云 **DingRTC 3.0 macOS SDK**。

二进制体积大 (~42MB)，**不提交进 git**（`.gitignore` 忽略 `*.framework` / `*.dylib` / zip）。
本目录只跟踪 `DingRTC.podspec` + 本 README；二进制按下面步骤本地重建。

## 重建 / 安装

```bash
cd apps/zhiban-app
./scripts/install_dingrtc_macos_sdk.sh
```

- 官方下载与集成文档: <https://help.aliyun.com/document_detail/2640099.html>
- SDK 下载页: <https://help.aliyun.com/document_detail/2640158.html>
- 版本: **3.9.0** (2025-04-15)，universal (x86_64 + arm64)，minos 10.14。

## 集成方式

`macos/Podfile` 里 Runner target 通过本地 podspec 引入:

```ruby
pod 'DingRTC', :path => 'Frameworks/DingRTC'
```

CocoaPods 负责 link + embed `DingRTC.framework` 与 `libffmpeg.dylib`。

F16 v0.7 会议能力扩展起引入: `MoziWhiteboard.framework`(互动白板)、`libhbal_se.dylib` +
`model/hbal_se_v*.nn`(智能降噪, 官方文档 2858119 要求随包)。beauty / SR 模块仍不引入。
安装脚本会一并复制; podspec 经 vendored_frameworks / vendored_libraries / resources 引用。

## 权限

`macos/Runner/Info.plist` 需有 `NSMicrophoneUsageDescription`（已加）。
macOS sandbox 需开麦克风 entitlement（`com.apple.security.device.audio-input`，见 Runner entitlements）。
