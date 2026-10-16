# 更新回归验证

所有 Flutter 命令在 `apps/zhiban-app` 运行。测试夹具独立于用户的知办AI、账号数据和 VS Code 调试进程；不要将测试 APK/APP 安装到正式包名或应用路径。

## 自动化回归

```sh
flutter test --no-pub test/desktop_update_cache_test.dart test/desktop_update_service_test.dart test/android_update_test.dart test/app_update_service_test.dart
flutter test --no-pub test/mobile_pages_ui_test.dart --plain-name '任务卡片尺寸与执行按钮居中'
```

## macOS 真实 Sparkle 安装

需要本项目已安装的 `macos/Pods/Sparkle`、Xcode Command Line Tools、Python 3。夹具使用独立包名 `cn.qkfintech.zhiban.updatefixture` 和临时生成的 Ed25519 测试密钥，不读取 Keychain / 发布私钥。

```sh
export EASYO_UPDATE_PROBE="$(mktemp -d /tmp/easyo-update-fixture.XXXXXX)"
python3 tool/update_verification/macos/build_fixture.py
flutter test --no-pub tool/update_verification/macos/native_cache_test.dart --reporter expanded
```

该测试用本地签名 DMG 模拟远端下载，然后将远端适配器切到离线。生产缓存服务恢复原包、开启真实 loopback HTTP；真实 Sparkle 验签、安装、重启夹具 100→101。最后读取 APP 的实际 CFBundleVersion，确认清理成功。它不验证公网发布链路或 Developer ID 公证。

签名拒绝单独使用新的临时目录：

```sh
export EASYO_UPDATE_PROBE="$(mktemp -d /tmp/easyo-update-fixture.XXXXXX)"
python3 tool/update_verification/macos/build_fixture.py
EASYO_REJECT_SIGNATURE=1 flutter test --no-pub tool/update_verification/macos/native_cache_test.dart --reporter expanded
```

预期：Sparkle 返回签名错误，仍为 100，缓存保留。测试完成后关闭独立夹具应用，再清理本轮 `$EASYO_UPDATE_PROBE` 目录；不要对真实知办AI执行退出或清理。

### macOS Delta 与两个完整包回退

```sh
export EASYO_UPDATE_PROBE="$(mktemp -d /tmp/easyo-delta-fixture.XXXXXX)"
EASYO_DELTA_MATRIX=1 python3 tool/update_verification/macos/build_fixture.py
flutter test --no-pub tool/update_verification/macos/native_delta_test.dart --reporter expanded
```

生成器从生产代码提取原生状态类、静默 driver 和下载回调，读取生产 Info.plist 的 ATS 配置；同一测试身份签名 100/101，再用官方 `generate_appcast` 生成补丁及签名。临时私钥在生成成功后删除。重建时仅清空此夹具目录的 `updates/`，避免生成器复用同版本的旧 Delta。

三轮均执行真实 Sparkle 验签、应用/安装、重启和实际构建确认后的缓存清理：匹配 Delta 的原生选包为 `[delta]`；Delta HTTP 404 为 `[delta, full]`；来源构建不匹配为 `[full]`。每轮结果保存在 `<场景>-evidence.json`、`<场景>-native.log`，仅关闭该目录中的独立测试进程。缓存的远端传输适配器将测试 HTTPS 地址映射到真实 loopback 服务，不修改生产缓存的 HTTPS 要求。

### 接入本地 Bus/Admin 和实际对象存储

1. 按项目配置启动本地 Admin/Bus；确认它们所连接的数据库和对象存储。**本地进程不等于本地数据库/存储**，不得改动现有稳定发布记录。
2. 新建独立 `dev` 草稿：macOS / universal / 0.0.101 / build 101。上传上述 `updates/fixture-101.dmg`，填写 `updates/appcast.xml` 对应完整包的 EdDSA 签名；通过 Admin 页面上传同目录 `.delta`，填写其 enclosure 的 `deltaFrom=100` 和 EdDSA 签名，然后发布该测试记录。
3. 确认 Bus 动态 appcast 输出 101 与 Delta，且两种包经 Bus 短地址下载后的大小、SHA-256 均与本地一致，再运行：

```sh
EASYO_LIVE_APPCAST='http://127.0.0.1:8080/api/agent-bus/v1/app/appcast?platform=macos&arch=universal&channel=dev' \
  python3 tool/update_verification/macos/verify_live_feed.py
```

该脚本直接让原生 Sparkle 访问 Bus 与存储，要求选包严格为 `[delta]`，实际安装并重启 101；证据为 `live-bus-evidence.json` 和 `live-bus-native.log`。它不替代上面的 Dart 缓存矩阵，两种测试不能并行使用同一夹具目录。结束后归档自己的 dev 记录并停止本轮服务。正式发布的 Developer ID、公证与真实知办AI替换须另行验收。

## Android 真机夹具

`android/` 在构建时复制生产 `AndroidUpdateBridge.kt` 与 provider XML 到生成目录，再编译独立 APK。Flutter embedding 只用于 MethodCall / Result 类型，不运行真实业务客户端。

```sh
# 将 <flutter-sdk>、<serial> 替换为本机实际路径和已授权真机。
android/gradlew -p tool/update_verification/android assembleDebug \
  -PflutterSdk=<flutter-sdk> -PfixtureBuild=101
# 将产物复制到独立临时文件 target-101.apk 后，再构建并安装基线 100。
android/gradlew -p tool/update_verification/android assembleDebug \
  -PflutterSdk=<flutter-sdk> -PfixtureBuild=100
adb -s <serial> install -r tool/update_verification/android/build/outputs/apk/debug/UpdateVerification-debug.apk
```

vivo 必须解锁手机并允许 USB 安装；锁屏可能直接返回 `INSTALL_FAILED_ABORTED`。本机遇到过失效 Gradle 代理，必要时仅对本次 Gradle 命令加 `-Dhttp.proxyHost= -Dhttps.proxyHost=`，不要修改用户全局配置。

操作入口为 `cn.qkfintech.zhiban.updateverification/.VerificationActivity`。每次使用 `--activity-clear-top` 重建页面以执行对应动作。结果在 `run-as cn.qkfintech.zhiban.updateverification cat files/result.json`。

```sh
adb -s <serial> shell am start --activity-clear-top \
  -n cn.qkfintech.zhiban.updateverification/.VerificationActivity \
  --es action start --es url 'https://httpbingo.org/bytes/1024'
# 后续动作：query；retry / install 需额外 --el downloadId <id>
```

验收顺序：

1. 记录网络原状态，临时断网后开始下载，退后台，等待超过 30 秒；重进和重复 start 必须保留原 ID，恢复网络后完成。结束必须还原网络设置。
2. HTTP 400 等终态不能自动重新入队；只有显式 retry 创建新 ID。公开 httpbingo 的 drip 总时长不得超过 10 秒，`duration=5&numbytes=1000&delay=0` 已验证有效。
3. 直接安装上述字节流必须返回 `invalid_package`，随后查询为 failed；不能交给系统安装器。
4. 安装成功验收需另建正常完成任务。将 target-101.apk 写入夹具 `files/fixture.apk`，执行 `seed-install-fixture` 将其注入真实完成任务的路径，再 install。此步骤将网络传输和 APK 安装分段验收，不能声称下载了真实发布 APK。
5. 授权或系统安装取消后仍为 ready；再次 install 经系统安装器将夹具升至 101。query 为 idle、tasks=[]、外部 updates 目录为空。不得覆盖/卸载 `cn.qkfintech.zhiban`。

2026-09-08 的 V2241A / Android 14 上已完成上述流程。原知办AI保持 1.1.9 / 11900。设备重启、通知栏完整交互和厂商长时间省电策略不在本次实测范围。

## Windows

Windows VM 上基线及本轮修正后的 `flutter build windows --debug --no-pub` 已由用户执行成功。独立 WinSparkle 版本比较、签名拒绝、取消保留和后续离线安装/启动/清理验收已通过。`flutter_inappwebview_windows` 的 CMake CMP0175 开发警告未阻断构建，不据此修改依赖缓存。

在已完成 Windows Flutter 构建的项目中执行（Windows PowerShell）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tool\update_verification\windows\prepare.ps1
# 将下面路径替换为 READY 输出；子 PowerShell 的环境变量不会传回当前进程。
$env:EASYO_UPDATE_PROBE='<READY 输出的完整目录>'
flutter --no-version-check test --no-pub tool/update_verification/windows/native_cache_test.dart --reporter expanded
```

需要 VS 的 CMake、Inno Setup 6、WinSparkle SDK 和 Git 自带 OpenSSL。SDK 可由 `-WinSparkleDir`、OpenSSL 可由 `-OpenSsl` 显式提供路径。准备脚本在临时 GUID 目录生成测试 Ed25519 密钥、编译原 bridge 的独立副本（只替换副本公钥）、构建 100/101 两个 EXE、用 Inno 打包并签名；签名结束立即删除临时私钥。不更改生产公钥或读取用户发布密钥。

测试传输使用本地签名夹具，下载入口为实际 `DesktopUpdateCache`，包括线上历史 `length=0` 情况；原生使用真实 WinSparkle DLL、生产 `EnsureInitialized` 和回调/消息窗口投递，fixture 接收消息记录事件，不运行 FlutterEngine 注册通道。完整客户端构建另外覆盖真实 bridge 链接；不能把夹具等同于完整业务客户端 UI 验收。

运行时按终端提示操作独立 **EasyO Update Verification** 安装器：第一次点取消并确认，第二次点击 Install、结束后点击 Finish。错误签名阶段自动验证。测试核对取消后仍为构建 100、进程重启/离线恢复远端仅下载一次、真实安装并启动 EXE 101 后才清理缓存。第二次安装交接后测试会主动关闭独立夹具以释放文件，不代表验收了正式应用的无人值守退出/重启。`RemoteSigned` 仅作用于这次 PowerShell 进程，不修改永久执行策略。

若成功安装那轮也被取消，保留原目录和缓存，使用仅继续安装的模式。该模式把远端适配器设为离线，要求新下载次数严格为 0，不重建夹具或丢弃现有包：

```powershell
$env:EASYO_VERIFY_INSTALL_ONLY='1'; flutter --no-version-check test --no-pub tool/update_verification/windows/native_cache_test.dart --reporter expanded; Remove-Item Env:\EASYO_VERIFY_INSTALL_ONLY
```

证据保存在 `$env:EASYO_UPDATE_PROBE` 中的 `prepare.log`、`native-events.jsonl` 和 `installer-result`。验收完成并确认夹具退出后，可删除该临时目录及 `HKCU:\Software\EasyOUpdateVerification\<该目录名称>` 测试配置。夹具不注册正式应用、桌面图标或卸载项，不触碰已有 `C:\知办AI` 和用户账号数据。

复制给用户的 PowerShell 多步命令要使用显式 `;` 分隔，避免聊天输入将换行折叠后把后续命令当作 `Set-Location` 参数。先检查 `$LASTEXITCODE` 再运行依赖步骤。
