# 知办AI · Windows 自动更新发布流程（WinSparkle）

完整设计见 `docs/features/F18-client-desktop-shell.md` §6。本目录是发布侧产物。

## 一次性准备

### 1. WinSparkle SDK（编译时）

下载 WinSparkle release（https://github.com/vslavik/winsparkle/releases），解压后任选一种方式让 CMake 找到：

- 解压到 `apps/zhiban-app/windows/runner/third_party/WinSparkle/`（免配置，已被 .gitignore 排除），或
- 设环境变量 / CMake cache：`WINSPARKLE_DIR=<解压目录>`

目录需包含 `include/winsparkle.h` 与 `x64/WinSparkle.lib` + `x64/WinSparkle.dll`。
未配置时 Windows 不编入更新 bridge，`cn.qkfintech.zhiban/update` 运行期为 MissingPlugin（不影响其余功能）。

### 2. EdDSA 签名密钥

复用 macOS Sparkle 的同一 ed25519 密钥对：

- 公钥已固化在 `windows/runner/winsparkle_bridge.cpp` 的 `kEdDsaPublicKey`，与 `macos/Runner/Info.plist` 的 `SUPublicEDKey` 一致。
- 私钥在 macOS 签名机的 Keychain（"Private key for signing Sparkle updates"），用 Sparkle 自带的 `sign_update` 工具签名。

### 3. Inno Setup

在 Windows 上安装 Inno Setup 6（含简体中文语言包）。

## 每次发版

```bash
# 1) 构建 Release（产物 exe：ZhiBanAI.exe）
flutter build windows --release

# 2) 打安装包（在 Windows，windows/packaging/ 目录下）
iscc /DMyAppVersion=1.0.1 installer.iss
#   产出：Output\zhiban-setup-1.0.1.exe

# 3) 用 Sparkle 的 sign_update 对 installer 签名（在 macOS 签名机）
#   输出形如：sparkle:edSignature="xxxx" length="12345678"
sign_update zhiban-setup-1.0.1.exe

# 4) 用 appcast-windows.xml 模板生成正式 appcast，替换占位：
#    {VERSION} {PUBDATE} {URL} {ED_SIGNATURE} {LENGTH}

# 5) 上传到托管（沿用 macOS 同一台）：
#    - installer → https://ai-office.zhichengcredit.com/win/zhiban-setup-1.0.1.exe
#    - appcast   → https://ai-office.zhichengcredit.com/appcast-windows.xml
```

客户端启动时 `WinSparkleBridgeRegister` 会自动 `win_sparkle_check_update_without_ui()`：
appcast 版本高于本地且 EdDSA 验签通过时，WinSparkle 自动弹出更新窗口，下载安装并重启。

## 注意

- 未做 Authenticode 代码签名：安装/更新首启会有 SmartScreen「未知发布者」提示，用户点「仍要运行」即可（见 F18 §6.2）。需要消除时再单独申请代码签名证书。
- `sparkle:version` 与客户端当前 `ProductVersion`（= `FLUTTER_VERSION`，来自 pubspec）比较；务必保证发布版本号单调递增。
- 不要把 WinSparkle 二进制或私钥提交进仓库。
