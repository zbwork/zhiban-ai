# 社区版本地定时任务验证（2026-11-05）

## 完成内容

原 TaskPage/TaskEditorDialog/TaskEditorContent 本地数据适配，侧栏开放自动任务；SQLite v7 定义/历史、客户端调度、完整单次时间、cron、恢复合并、员工串行、防重复认领；复用员工聊天模型/技能/目录/权限/停止链路；原会话查看结果。

## 验收结果

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| 无账号路由、局部 Service 作用域 | verified | 实际 LocalWorkspaceApp 路由测试，根远端 Service/员工 Provider 初始化即抛错，页面仍成功加载 |
| 原页面新建/编辑/暂停/恢复/立即执行/删除/历史跳转 | verified | Widget 测试通过，原组件类型验证，HttpOverrides 拒绝网络且请求次数为 0 |
| cron、单次完整时间、漏跑合并、防重入 | verified | 本地调度测试，含月末、闰年、周日 7、日期/星期 OR |
| 重启、v6 升级、任务删除和员工删除 | verified | 真实 SQLite 文件重开及升级，旧员工/消息保留，已认领单次不重跑，历史保留 |
| 聊天执行衔接 | verified | 控制器测试通过任务 Service 调用 send，当前模型、员工人设、技能和消息落库正确 |
| 工具权限 | verified by reuse | 调度直接调用原 send/runtime，使用原审批弹框；无提升权限和凭据持久化改动；已有权限菜单回归通过 |
| 默认服务端模型与表单 | verified | 既有 cron model、delivery target、selectable agents、utils 测试通过 |
| 真实模型/工具人工联调 | not verified | 未使用真实 API Key 或发起收费请求 |

## 执行验证

- 共享包：flutter test --no-pub --reporter expanded，9 个文件，41 项通过：local_task_service_test、local_workspace_controller_test、local_workspace_store_test、local_workspace_entry_test、local_permission_control_test、task_bus_cron_model_test、task_editor_delivery_target_test、task_selectable_agents_test、task_utils_test。
- 桌面：flutter test --no-pub --reporter expanded test/local_task_page_test.dart test/local_workspace_shell_test.dart，4 项通过。总计 45 项通过。
- 两个子项目定向 flutter analyze --no-pub：通过（最终结果以命令输出为准）。
- flutter build macos --debug --no-pub：通过，构建内 Bridge 签名校验通过。
- git diff --check、python3 .github/scripts/check-community.py .：通过。仓库无 scripts/check-repo-hygiene.sh，未执行该不存在的脚本。

未验证 Windows、macOS GUI 人工操作、真实付费模型和工具执行。本次未重启用户正在运行的客户端。构建出现已有 Bridge macOS 13.0 对链接目标 12.0 的警告，未阻塞 Debug 构建，不据此声称 macOS 12 兼容。未修改此前工作区权限修复的语义，未提交代码。


## Review 修复回归

修复日期/星期通配步进丢失过滤，以及任务认领与普通聊天抢占的竞态。新增 LocalEmployeeExecution，任务、聊天与删除共用 CancelToken 所有权；任务认领前取锁，未认领或终态回写后释放，普通聊天清理失败也释放。工具审批及完全访问生命周期沿用原行为。

新增 5 项测试场景：Cron 通配步进组合（含显式日期配星期步进和原 OR）；任务认领 IO 前排斥聊天；聊天占用时单次任务保持待执行、随后只执行一次；认领异常释放；认领期间停止不消耗任务。现有控制器测试新增同步监听 busy 并立即调用真实 send 的竞态断言，确认聊天被拒且任务成功落库。

共享包 9 文件 46 项、桌面 2 文件 4 项通过，共计 50 项。定向静态分析、macOS Debug 构建、git diff --check 和社区材料检查结果见本次完成说明。未跑 Windows、真实模型/工具人工联调；未重启用户当前客户端。

Review 中关于星期 */2 从 2026-11-02 后应落在 11-04 的预期不正确：星期从周日 0 起算，*/2 为 0/2/4/6，11-03 周二符合条件。修复测试以正确集合为准，不把这个日期当成错误；使用显式日期配星期步进验证星期过滤不能丢失。
