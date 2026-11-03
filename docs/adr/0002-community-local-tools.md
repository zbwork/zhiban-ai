# ADR 0002：免登录本地开发工具与数字员工执行

凭据决策：模型与Bridge BYOK使用应用私有明文文件，重启保留；目录0700/文件0600（macOS/Linux）。不读取旧钥匙串，旧Key需重新填写。用户明确接受明文风险，详见本地工作区需求“本地明文凭据”。

## 决策与边界

社区版复用既有本地开发工具页面、Bridge BYOK 设置及备份/恢复机制，开放头像菜单入口。检测、安装、API 设置、启动不依赖产品登录，不注册设备、不拉取产品目录。原商业路径保持不变。

数字员工使用独立 community desktop helper 入口，复用 DesktopEngine、CodexDesktopEngine、DesktopBroker、LocalSupervisor、LocalPolicy 和原文件/命令/Office 工具，不复用 DesktopChannel。无 JWT、远程设备注册或 Bus 租约。本地 scope 明确为 community/device-local；session 是 helper 生命周期随机 ID，不冒充服务器账户。每轮任务限时 15 分钟，父进程管道关闭或停止撤销执行能力。

真实模型 Key 仅从应用私有凭据文件读取，经父子进程 stdin 进入宿主内存；工作进程仅取得随机、按任务隔离的回环访问能力。Key 仅持久化于专用凭据文件，不进入 argv、环境、普通配置文件、SQLite 或错误日志。模型代理固定到用户配置的 HTTPS 服务商（本机允许 HTTP），禁止重定向；不接受模型或工具指定上游地址。Codex 使用 Responses 协议，服务商必须兼容；不静默替换模型或引擎。DeepSeek Harness 支持 OpenAI compatible / Anthropic messages，其他协议继续保留原文本请求。

默认工作目录在用户文档目录的知办AI/community/device-local 下，每员工独立。只读与新增文件沿用 assist；覆盖、删除、shell 等沿用原审批策略，由原确认弹框展示真实操作后处理。拒绝、超时、停止均不得继续执行。文件访问及命令进程保留系统隔离，不能为免登录绕过 sandbox。生成文件留本地，不上传云盘。

每轮独立 helper，员工运行数据放在应用支持目录 community-runtime/<员工 UUID>，可并行隔离，结束关闭 helper。原输入区 AgentControlButton 选择模型/工作目录；目录通过系统选择器授权，创建/编辑保留该员工目录。未选择则使用独立默认目录。完整访问模式本轮不开放，默认 assist 不提升为 full。输出从已验证 ArtifactStore 复制到私有 outputs/<run> 快照，原消息附件组件打开；重写工作文件不破坏历史快照。SQLite v6 增加 timeline，重启仍保留工具调用状态。

未适配 Harness 的 Google 原生协议继续文本分析，不显示执行成功或自动切换服务商；Codex 明确要求 OpenAI compatible / Responses，发送前拒绝不兼容协议。

## 行业最佳实践与 EasyO 适配性

来源：[Agent Skills](https://agentskills.io/specification)、[Codex app server](https://developers.openai.com/codex/app-server/)、[Claude Code third-party integrations](https://docs.anthropic.com/en/docs/claude-code/third-party-integrations)、[OWASP Secrets Management](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)。

行业做法：本机工具与模型认证分离、按任务最小授权、写文件/命令需要明确权限、凭据独立安全存储。当前上下文：仓库已有安全 broker/执行器和 Bridge BYOK，但社区聊天未接入。采用 adapt：增加独立启动适配器，保留执行器和审批；adopt 原 Bridge BYOK/备份恢复。不采用伪造登录、复制新的 agent loop、在普通配置中复制 Key或把技能简介当可执行包。官方文档地址在开发网络返回不可用内容，具体协议以已锁定 SDK 和已有集成测试为准，不据此声称新版本兼容。

## 验收

- 无 token 可从头像打开原本地开发工具页，检测无产品网络请求，API 设置/恢复沿用 Bridge。
- 员工创建/编辑选择本地引擎并回显；模型仍只在对话中选择。
- 模型通过本地 broker 调用真实文件读写与 shell；危险操作先审批；拒绝和停止阻止后续执行。
- 聊天和结果本地持久化，失败不伪报成功，工具缺失或协议不兼容给出明确提示。
- 现有员工、消息、技能及商业模式行为保留；自动任务继续要求登录。
