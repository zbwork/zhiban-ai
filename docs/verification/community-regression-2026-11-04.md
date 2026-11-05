# 社区版回归记录（2026-11-04）

范围：main 的 0ea29ca 加当前未提交的未登录入口隐藏改动。保留现有用户数据，不读取真实 API Key，不修改真实工具配置、不执行付费模型请求。

## 结果

| 检查 | 结果 |
| --- | --- |
| 共享客户端本地工作区、附件、技能安装/恢复、凭据、模型配置、输入历史、滚动、Bridge 与链接颜色 | 75 项通过 |
| 桌面本地壳层/设置、工具 API 设置、附件预览 | 20 项通过 |
| 随最终 macOS 包运行时：工具目录、Office Schema、模型错误/受限重试、代理边界、真实文件/命令及允许/拒绝/取消/Codex | 10 项通过；模型由本机模拟服务提供 |
| Go credential 包 | 禁用缓存重新执行通过，覆盖文件权限、持久化、目的端绑定等 |
| 客户端及桌面定向静态分析 | 均无问题 |
| 线上匿名技能列表 | success=true，81 项，3 分类，total 与实际长度一致 |
| 线上匿名技能包抽样 | zb_product_roadmap_metrics 0.1.0，770815 字节，响应 SHA-256 与内层 manifest 包摘要均一致；包含 SKILL.md 和许可证 |
| 当前 macOS 客户端 | 社区仓库 Debug 进程存在，codesign --verify --deep --strict 通过 |
| git diff --check / community 材料检查 | 通过；材料脚本不替代产品、安全和授权审查 |

## 扩大范围后的失败

### 后续适配结果

用户要求修复后，以上同一组 6 个桌面测试文件重跑：85 项通过、0 失败（原 83 项加 Codex/Claude 各 1 条串联用例）。以下 23 项失败保留为首次检查历史，已不代表当前测试结果。

开发工具测试保留原安装/验证/恢复/代理/升级/失败处理断言，按实际“一键配置工具”及自有模型服务文案适配；设备授权缺失用例改为验证社区 BYOK 无需知办登录授权且不调用 register/enable。新增串联用例从卡片 API 设置打开既有模型选择器，搜索模型、保存临时文件中的对应服务商 Key，断言 Codex /v1 与 Claude 根地址、Key 不显示，再执行 CLI/桌面配置与验证顺序。页面仅增加可选 Bridge 会话工厂并逐层传递，默认生产路径不变。

侧栏测试改为验证无计费区时折叠保持草稿、导航和角标；自己名片断言无“发消息”，保留身份、弹层和其他菜单断言。未 skip、删除或关闭原用例。新增测试初次因真实文件 IO 落在 fake async 中而超时/未保存，改用 runAsync 及有界等待；不修改生产时序掩盖问题。

定向 flutter analyze 覆盖工具页面及三个适配测试文件，无问题。git diff --check 通过。本次未重新构建客户端：唯一生产变动为可选依赖注入，不改变默认行为，上一轮功能构建已通过；无真实模型调用与真实配置写入。

桌面 6 个文件合跑：60 通过、23 失败，不能报告为全量通过。

- local_coding_tools_page_test.dart：21 失败。断言仍围绕商业版“一键接入知办”及授权接入流程，社区分支已使用“API 设置”和自有 Key。需要另行适配为社区模式覆盖，不能将这些失败等同真实工具安装/配置已全部验证。
- desktop_sidebar_test.dart：1 失败，读取 SidebarBillingSection State，但该区在 communityEdition 下已隐藏。
- sidebar_profile_popover_test.dart：1 失败，期待自己名片存在“发消息”；当前名片没有消息/通话回调时隐藏整组操作。

本轮未通过修改生产行为或跳过断言来让旧测试变绿。新的本地壳层/设置和模型 API 设置测试均通过。

## 执行命令

在 packages/zhiban-client：

```sh
flutter test --no-pub --reporter expanded test/local_workspace test/prompt_input_layout_test.dart test/chat_stream_scroll_follow_test.dart test/local_coding_bridge_client_test.dart test/pages/model_service/provider_key_link_test.dart
flutter analyze --no-pub lib/pages/local_workspace lib/pages/model_service/widgets/provider_detail_panel.dart lib/pages/chat/widgets/create_agent_dialog.dart lib/pages/chat/widgets/chat_session_view.dart lib/pages/chat/widgets/prompt_input/prompt_input.dart lib/pages/settings/settings_page.dart test/local_workspace test/pages/model_service/provider_key_link_test.dart
```

在 apps/zhiban-app：

```sh
flutter test --no-pub --reporter expanded test/local_workspace_shell_test.dart test/local_coding_api_settings_test.dart test/attachment_preview_panel_test.dart
flutter analyze --no-pub lib/layout/main_layout.dart lib/layout/widgets/sidebar_profile_popover.dart lib/pages/local_coding_tools/local_coding_api_settings_dialog.dart test/local_workspace_shell_test.dart test/local_coding_api_settings_test.dart
# 扩展检查：存在上述 23 项失败
flutter test --no-pub --reporter expanded test/local_workspace_shell_test.dart test/local_coding_api_settings_test.dart test/local_coding_tools_page_test.dart test/desktop_sidebar_test.dart test/sidebar_profile_popover_test.dart test/attachment_preview_panel_test.dart
```

运行时使用最终 App 包内 Node 和 dsh-runtime：设置 COMMUNITY_RUNTIME_TEST_ROOT 为包内 arm64/dsh-runtime，执行 node --test test/community-runtime.test.mjs test/community-attachments.test.mjs。系统 PATH 没有 npm，首次 npm run build 未能执行；改用已由最近 macOS 构建编译的最终随包运行时，未把未执行的 npm build 计为通过。

在 apps/zhiban-local-bridge：go test -count=1 -v ./internal/credential。

线上实测匿名 GET /api/public/v1/skills、POST /api/public/v1/skills:export；包只下载到系统临时目录，不安装到用户实际工作区、不执行技能脚本。

## 未验证和边界

- 本轮无可调用的桌面 GUI 点击工具；组件测试覆盖交互，但不等于真人桌面逐页视觉验收。未实测原生选文件窗口、跨 App 拖拽、浏览器打开官网、视觉闪烁和滚动观感。
- 未使用用户密钥调用真实服务商；BeeBridge 间歇 HTTP 400、Claude 真实账户与计费模型可用性仍待实际联调。
- 未在用户真实工作目录或真实工具配置上执行写操作。运行时文件/审批验证使用临时目录和真实执行器。
- 线上包只抽样一个，不能据此宣称全部 81 个包可用；安装与完整资源快照另由自动测试验证。
- 自建 Bus 地址配置及账号登录流程尚未接通，本轮不能验收登录后功能。
- 不重跑整仓库测试；本轮围绕社区工作区及相邻桌面组件，无 Windows 实测。

本轮未发现定向社区回归中的新增失败；扩展测试兼容性待清理，真实 GUI 和模型联调未完成，不能称为完整手工验收通过。
# 本地聊天权限修复补充

- 已验证：复用原权限菜单和完全访问确认框，三档权限、取消/勾选确认、回复期间禁用。普通模式按员工保存，完全访问仅内存保存；覆盖员工隔离、改目录保持、控制器重建降级。
- 已验证：community submit 不再固定 assist，校验模式并经原 workspace 确认凭证接入 LocalPolicy。无凭证 full 在模型调用前失败；DSH/Codex 的 ask 写入、assist 常规写入、full 命令、拒绝/取消均使用真实执行器验证；full 上传单次批准保留。
- Flutter：local_workspace、local_agent_design_test、local_agent_menu_navigation_test 共64通过、2个原有条件跳过（商业版云端创建），未新增跳过。旧文件卡片测试按当前打开/显示按钮及回调验证，保留深浅主题覆盖。
- Runtime：打包 Node 执行 community-runtime.test.mjs 与 community-attachments.test.mjs，16通过、0失败、0跳过；模型为本地 HTTP mock，文件和命令真实执行。
- 静态分析：本地工作区、原权限组件及相关测试无问题；macOS debug 构建通过，保留既有 Go macOS 链接版本警告。
- 未运行 Windows 构建、真实付费模型及人工 GUI 点击。本仓库无 scripts/check-repo-hygiene.sh，改用 git diff --check。在线 security 参考返回 Forbidden，未据此声称核验最新版。
