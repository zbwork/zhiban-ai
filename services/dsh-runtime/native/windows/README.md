# Windows 本地执行组件

契约：[ADR-0046](../../../../docs/adr/0046-local-agent-desktop-platforms.md)。需 Windows 10/11 x64；普通用户执行，不需要安装时修改 loopback exemption，不需要全局 Node。

## 构建与验收

构建机安装 VS C++、CMake、Python 3 与 Flutter。客户端 `flutter build windows --release` 自动编译本组件，再调用 `apps/zhiban-app/scripts/bundle_local_agent_windows.py` 装配固定 Node/DSH；隔离探针失败会阻止打包。Inno Setup 原有递归安装规则会包含 `local-agent`。

独立后端验证（PowerShell，在 `services/dsh-runtime`）：

```powershell
# 使用 Node 24.19.0 x64，并先安装 VS C++、CMake、Python 3。
npm ci
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-codex-windows.ps1 -BuildNative -NodeExe (Get-Command node).Source
```

Node 须为 24.19.0；也可用已构建安装包中的 Node，避免系统 Node 不一致。`test/desktop/windows.test.ts` 必须在 Windows 实际执行，不能把 skipped 算通过。真实 DSH 冒烟使用脚本模型，无真实账号或费用；另需客户端真实模型、审批、文件归档、重启及安装升级验收。

## 实现边界

- 子进程每次使用新的 AppContainer profile/SID；只给目录的该 SID 加 ACL，退出撤销该 SID，不恢复可能覆盖并发更改的整份旧 ACL。
- Program Files 等只读安装目录若不允许用户修改 ACL，不请求提升权限，使用系统已有读取权；读取不足时目标探针失败。
- 默认无网络 capability；预加载脚本只把 broker 的固定 loopback 端口连接换成 named pipe；操作系统负责拒绝其余网络。获得 full 的命令才带 InternetClient/PrivateNetworkClientServer capability。
- 进程挂入无 breakaway 的 Job 后才 resume；CPU、内存、进程数由 Job 约束。原生 broker 还持有父进程同步句柄；父进程死亡立即结束 Job。终止 broker 会关闭 Job，结束整棵子进程树。
- 当前未完成 Windows 实机验收。尤其需验证 named pipe/AppContainer 跨边界兼容、受限 PowerShell、受保护 ACL/安装目录，以及强杀后残留临时 profile/ACL 的清理。强杀产生的孤立 SID 不会被下一轮复用；后续仍应增加崩溃清理账本。

## Codex App Server 验收

脚本失败返回非零，结果位于 `%TEMP%\zhiban-codex-acceptance\result.json`，包含组件自检和真实固定版本 Codex 协议/工具/取消测试；stdout JSON 与 stderr 分开保存。Windows 目标为 x64，macOS 两种 CPU 通过各自包验收，不能用 macOS 测试代替 Windows。

Codex 是 Rust 原生进程，不能依赖 Node preload 劫持 HTTP。它与专用 Node TCP listener 位于同一 AppContainer SID，通过该 listener 转到已有固定目的端口的 named pipe；无网络 capability、无 loopback exemption。组件探针会先验证转接 nonce 往返再启动 Codex。最终仍需 Windows 安装包、真实模型和客户端手动验收；目前没有 Windows 实机结果。
