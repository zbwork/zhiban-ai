# EasyO 近期修复对照（2026-11-05）

## 范围与判断

| EasyO 提交/问题 | 社区模式判断 | 处理 |
| --- | --- | --- |
| 7b5638d25：Codex 祖先项目配置发现 | 相同 transport，用户目录下的任务有相同风险 | 追加 project_root_markers=[]，不扩大隔离权限 |
| 7b5638d25：Responses 默认 auto 被网关错误解析 | BYOK 同样经过 DesktopBroker | 只省略 Responses 默认 auto，保留显式策略和其他协议 |
| 7b5638d25：ready 前检查引擎 | 社区每轮 helper 不走 ChatNotifier/常驻 LocalAgentService 能力检查 | 保留服务端参考分支，未移植 |
| 2e14c05de：错误码在客户端展示中丢失 | 同一 core formatter；社区终态另有直接保存文案路径 | 回移安全错误格式化，并接入社区终态持久化 |
| 2e14c05de：常驻通道恢复时加载递归/转圈 | 社区使用 LocalChatModelControl，无该重连加载流程 | 未移植 |
| 1b0bd1aca、34fc7fc05、2e14c05de：账务与余额快照 | 当前免登录 BYOK 社区聊天不走商业余额/扣费链路 | 未移植商业账务 |

本次结论限于上述近期修复在当前社区本地模式中的适用性，不表示保留的服务端参考代码已与商业版全量同步。EasyO 已有 apps/zhiban-app/pubspec.yaml 改动未触碰。

## 验证

- core：dart test --reporter expanded test/error_utils_test.dart，15 项通过；定向 dart analyze 无问题。core 为纯 Dart 包，初次 flutter test --no-pub 因尚未生成测试依赖解析失败，改用 dart pub get 和 dart test；生成缓存已清理，lockfile 已恢复，未引入依赖变更。
- client：flutter test --no-pub --reporter expanded test/local_workspace/local_workspace_controller_test.dart test/local_workspace/local_workspace_entry_test.dart，3 项通过；控制器定向 flutter analyze --no-pub 无问题。
- macOS：flutter build macos --debug --no-pub 成功，含 TypeScript 编译；仍有既有 Go bridge macOS 13 对最低 12 的链接警告。调试 App 重新 ad-hoc 签名后，codesign --verify --deep --strict 通过。
- Node 24.19.0 对最终包内 runtime 运行 codex-transport.test.mjs、community-runtime.test.mjs、community-attachments.test.mjs：19 项通过。包含工具策略矩阵、真实 DSH/Codex、用户目录祖先、审批/拒绝/取消、附件与模型代理边界。首次新增 home-parent 场景漏加入测试审批允许列表，导致 shell 被测试主动拒绝；修正测试夹具后整组通过，未修改生产审批策略。
- 使用已有 build/local-agent-bundle 中钉住的 Node 和最终 App runtime，因验证对象就是打包组件；未读取真实用户配置、Key 或业务数据。测试模型由本机 HTTP 模拟服务提供，未发起付费模型请求。
- python3 .github/scripts/check-community.py . 与 git diff --check 通过。公开仓库无 scripts/check-repo-hygiene.sh，采用既有社区材料检查，不将其等同完整产品/安全审查。

未验证 Windows 实机、Release/公证、真实服务商请求或全量测试。已构建本地 Debug 包，本次未重启用户当前运行的客户端、未提交或推送。
