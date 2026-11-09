# Windows 本地执行组件

社区版支持 Windows 10/11 x64，终端用户无需另装 Node、Python、Rust 或 Go。完整构建与验收记录见[社区版 Windows 1.0.0](../../../../docs/releases/community-windows-1.0.0.md)。

## 构建

构建机需要 Flutter 3.35.6、VS C++/Windows SDK、Python 3.12+、Go 1.26.1+、Rust 1.93.0 和 Inno Setup 6。安装器另需 WinSparkle SDK 与签名有效的 Microsoft WebView2 离线安装器，配置见客户端 `windows/packaging` 和 `scripts/prepare_webview2_windows.ps1`。

`flutter build windows --release` 自动编译 AppContainer/Job broker 和路径 addon，装配固定 Node 24.19.0、DSH 与 Codex 0.132.0 兼容构建。Codex 源码、补丁、工具链、二进制摘要校验全部保留；`ZHIBAN_CODEX_BUILD_CACHE` 可指向构建机已有的短路径缓存。组件自检不过不能生成可交付安装包。

已构建客户端后的运行测试（仓库根目录，交互用户会话）：

```powershell
$bundle = (Resolve-Path 'apps/zhiban-app/build/windows/x64/runner/Release/local-agent').Path
$env:COMMUNITY_RUNTIME_TEST_ROOT = Join-Path $bundle 'dsh-runtime'
& "$bundle/node/node.exe" --test --test-concurrency=1 services/dsh-runtime/test/community-runtime.test.mjs services/dsh-runtime/test/community-attachments.test.mjs services/dsh-runtime/test/codex-transport.test.mjs services/dsh-runtime/test/community-windows.test.mjs
```

上述模型是本机脚本夹具，不需要模型账号或调用费用。安装后还须以非提升权限执行 `apps/zhiban-app/scripts/verify_windows_install.ps1 -InstallDir <安装目录>`，并在该权限下运行工具/续答测试；安装检查与构建检查分别记录。

## 隔离边界

- 每个子进程使用新的 AppContainer/SID 和 kill-on-close Job。目录只增加该临时 SID 的权限，退出撤销同一 SID，不恢复整份旧 ACL。
- 默认无网络 capability；只把固定 broker 端口转换为受控 named pipe。经用户确认的 full 命令才获得网络和主目录授权。
- full 的持久化保护目录若不存在，必须位于已授权可写根下；先创建目录并固定不可替换的句柄，再施加唯一 SID 的拒绝 ACL。退出后仅尝试清理本次创建且仍为空的目录；不丢弃保护规则。
- Program Files 等只读安装树使用安装器授予的 AppContainer RX。普通客户端不请求权限提升，不改防火墙或 loopback exemption。
- 进程挂入 Job 后才恢复执行；父进程死亡或 broker 被结束，整棵受管进程树随 Job 结束。
- Codex 为固定版本原生程序，经专用 TCP listener 和 named pipe 访问 broker；不借助全局 Codex 或 Node preload 伪造原生网络限制。

Windows 11 x64 构建机的结果记录在发布文档中；Windows 10、Windows ARM64 原生包、真实模型与 GUI 各页面验收须分别报告，不能用组件测试代替。
