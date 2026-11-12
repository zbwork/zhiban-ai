# 可选服务器工作区验证（2026-11-10）

基础版本：公开 main `d431844`（v1.0.0）。实现分支：`codex/community-server-workspace`。

## 已验证

- zhiban-client：`flutter test --no-pub` 定向运行 server_connection_test、server_connection_dialog_test、session_service_test、local_workspace_controller_test、local_task_service_test、local_workspace_entry_test，28 项通过。涵盖地址校验、匿名检测、错误/重定向拒绝、旧请求与凭据写入隔离、保存地址不激活连接、本地模型/聊天/任务与原 UI 回归。
- zhiban-client：contact_providers_cache_test、local_agent_call_recovery_test 加连接/会话测试共 23 项通过（与上组部分重叠，不累加为独立总数）。验证 clear 后的通讯录刷新不能继续查询或回填旧数据。
- zhiban-app：community_workspace_switch_test、local_workspace_shell_test、desktop_sidebar_test，7 项通过。真实临时 SQLite 与内部 ProviderScope 验证本地→A 登录页→本地→B 登录页；旧 Token 清空，本地员工和模型配置保留，返回创建新控制器。没有使用真实账户登录。
- zhiban-core：`dart test test/session_network_test.dart`，3 项通过；刷新写盘后连接失效不能填回旧内存 Token。
- 修改的 Dart 文件和测试静态分析无问题；`git diff --check` 通过。
- macOS arm64 Debug：先 `flutter build macos --debug --no-pub --config-only`，再用 Xcode 独立 derivedDataPath/SYMROOT 构建，成功。路径 `/tmp/zhiban-server-workspace-preview/Products/Debug/知办AI社区版.app`；不替换运行中的客户端。增量构建的 App.framework 自身签名有效，但外层 seal 仍记录旧版本；导出该包原 entitlements 后仅对外层包重新 ad-hoc 签名（未使用 --deep、未扩大权限），最终 `codesign --verify --strict` 通过。未修改项目签名规则。
- 组件截图由真实 ServerConnectionDialog 渲染到 PNG，使用随包字体和图标；非设计稿，非真实后端登录验收。

## 未通过/未覆盖

- 扩展回归 response_interceptor_test 的一条旧文案断言失败：预期模型格式错误文案不含错误码，当前实现含 `model.request_invalid`。该格式化实现和断言均非本次修改。
- 扩展回归 local_task_page_test 的一条旧提示断言失败：寻找“关闭后暂停”，当前任务页没有该文案。任务页面未修改，本地任务 service 回归通过。
- 没有运行全仓测试、Windows 构建、Release 签名/公证，也没有部署新服务器或用真实账户验证聊天、IM、文件及远程模型/工具。本阶段仅交付连接与切换基础，不将其描述为全业务接入完成。
- 仓库未提供 `scripts/check-repo-hygiene.sh`；以 diff、变更文件和新文档链接检查替代。Dart 测试生成的 lockfile 变更已还原，临时 .dart_tool 已移出仓库。

## 对照验收

默认本地/保存地址、地址约束、失败重试、原密码登录页、返回本地、A/B 凭据隔离、本地数据保留：测试验证。真实登录后的团队业务与运行中的 IM/Agent 退出：已接入既有清理代码，仍需真实部署验收。

## 2026-11-11 接入指南入口

连接弹窗底部左侧新增“接入指南”，使用系统浏览器打开 GitHub README；同步需求契约。修改文件静态检查与两项既有弹窗回归通过，真实组件截图确认布局正常。未通过点击启动浏览器验证外链；URL 固定为公开仓库 `https://github.com/zbwork/zhiban-ai#readme`。

macOS arm64 Debug 预览包已重新构建；沿用上述方式保留原 entitlements、仅更新外层 ad-hoc 签名，`codesign --verify --strict` 通过。没有重启用户正在运行的客户端。
