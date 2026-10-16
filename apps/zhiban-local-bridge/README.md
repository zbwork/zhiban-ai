# zhiban-local-bridge

F31 本地编程工具的确定性桌面伴生二进制。当前已实现 macOS 上的严格 stdio JSON-RPC、Codex CLI / Claude Code CLI 只读发现、设备身份与 Keychain 授权保存、短期凭据 helper、隔离配置、项目 bookmark、单次启动 ticket、原生 Terminal consumer，以及由 zhiban-app Xcode build phase 生成的 app-like nested helper 打包。

## 当前安全边界

- 不监听端口，不常驻后台；
- 只允许 helper 直连编译期固定的 dev/test/prod Bus 换票 endpoint；不继承代理环境、不跟随重定向；
- Ed25519 私钥种子与设备交换授权分别保存在 non-sync、ThisDeviceOnly 的 macOS data-protection Keychain 项；
- RPC 不接受路径、命令、URL、环境变量或任意 argv；
- 只对唯一且已识别来源的候选执行固定 `--version`；
- 项目路径只通过系统 picker bookmark 进入 Bridge；Terminal trampoline 只含 helper 路径和一次性 ticket ID；
- consumer 在 `exec` 前重新校验目录、安装和 profile，并移除目标凭据、网关覆盖和动态加载器环境；
- stdio 模式 stdout 只输出 JSON-RPC frame；helper 成功时 stdout 只输出一行短期 Token，失败时为空；
- Terminal 启动只代表 L1，不把本地配置或 loopback smoke 冒充为真实网关 L3/ready。

完整协议见 [`docs/contracts/local-coding-tools-contract.md`](../../docs/contracts/local-coding-tools-contract.md)，项目启动见 [`F31 M1F-B 计划`](../../docs/features/F31-local-coding-tools-m1fb-project-launch-plan.md)，隔离实机验收见 [`F31 本地黑盒验证方案`](../../docs/features/F31-local-coding-tools-local-blackbox-validation.md)。

## macOS 发布形态

生产 Bridge 不是裸命令行文件，而是：

```text
知办AI.app/Contents/Helpers/ZhibanLocalBridge.app/
  Contents/
    Info.plist
    embedded.provisionprofile
    MacOS/zhiban-local-bridge
```

这是因为 data-protection Keychain 的 Keychain access group 需要受 provisioning profile 授权。Debug 的 ad-hoc wrapper 只用于包结构、架构和 L0 smoke，不带该受限 entitlement，不能用于注册设备或证明 Keychain 可用。发布签名和环境变量见 [`zhiban-app README`](../zhiban-app/README.md#本地编程工具-bridge)。

## 进程入口

```text
# zhiban-app 按需拉起的 stdio JSON-RPC
zhiban-local-bridge

# Codex auth.command / Claude Code apiKeyHelper 使用
zhiban-local-bridge credential get --target codex_cli
zhiban-local-bridge credential get --target claude_cli

# 系统 Terminal trampoline 使用；不是 JSON-RPC 方法
zhiban-local-bridge launch consume --ticket <one-time-ticket-id>
```

stdio 初始化后可公布 `tool.detect`、credential、config、`project.grant.create`、`launch.plan` 与 `launch.execute` 等已实现方法；接了版本目录后还公布 `catalog.apply`（`install.plan` 随之接受 `upgrade / rollback`，`tool.detect` 多带 `available_version / rollback_version / update_available`，契约 §2.7.4；各环境信任的目录公钥在 `internal/catalog/keys.go`）。注册 HTTP 仍由已登录 zhiban-app 执行；Bridge 不接收 App access token。

## 本地验证

```bash
go fmt ./...
go vet ./...
go test ./...
go test -race ./...
go build ./...
```

普通测试不会打开 Terminal 或调用真实 Claude Code。两个隔离黑盒必须显式开启：

```bash
# 会短暂打开系统 Terminal；只使用临时 HOME、临时项目和假 CLI
ZHIBAN_RUN_TERMINAL_SMOKE=1 go test ./internal/launch -run '^TestMacOSTerminalLaunchSmoke$' -count=1 -v

# 调用已安装的锁定版 Claude Code；只连接 loopback Messages stub
ZHIBAN_RUN_CLAUDE_GATEWAY_SMOKE=1 go test ./internal/launch -run '^TestClaudeCodeLoopbackGatewaySmoke$' -count=1 -v
```

当前已验证 Go/cgo arm64/x86_64 构建、universal 合并、ad-hoc Hardened Runtime wrapper、Xcode Debug 内嵌、stdio initialize、真实 Terminal 启动链和真实 Claude Code `2.1.263` 的 loopback Messages 兼容。尚未在具备 helper provisioning profile 与 Developer ID identity 的发布签名机完成真实 Keychain、公证、Bus 注册或真实网关 L3，不得把 ad-hoc/loopback 结果作为生产 Bridge 分发。自动测试不会写开发者本机的真实 Keychain。
