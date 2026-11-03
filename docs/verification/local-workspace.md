# 社区版本地工作区验证（2026-11-02）

## 本地聊天拖入文件（2026-11-03）

- macOS Debug 构建、最终 deep strict 签名校验通过，已重启社区版；桌面旧 export 与共享包定向 analyze 无问题。
- 根因：DesktopDrop 仅包裹原服务端 ChatPage，本地会话未接入。将原组件移入共享包，桌面旧路径 export；本地会话拖入与点击选文件复用同一解析/校验流程。并发导入受 reading 锁保护，异步返回检查员工仍存在。更新需求文档。
- 本地入口与附件 4 项测试通过：原选文件、拖入后的附件名与 PromptInput State、文件解析/超限/格式边界。共享包定向 analyze 通过，community 检查与 diff check 通过。尚未做 Finder 原生手动拖拽、Windows/Release 验证。
## API 设置摘要排版（2026-11-03）

- macOS Debug 构建与最终 deep strict 签名校验通过，已重启社区版。
- 原弹框、模型按钮与选择器保留；摘要采用主题浅底/边框和 Table 固定标签列，地址/模型值对齐并换行；管理入口独立右对齐。无新增编辑控件。更新需求文档。
- 原 API 设置 7 项回归通过，修改页面和测试 scoped analyze 无问题，community 检查及 diff check 通过。未增加样式镜像测试，未做桌面人工视觉/深色主题/Windows/Release 验证。
## 工具设置只从模型服务选择（2026-11-03）

- macOS Debug 构建与最终 deep strict 签名校验通过，已重启社区版。
- 移除地址/模型/Key 输入框与手动模式；保留原选择器，显示只读摘要及原管理模型服务入口。保存前重读配置，变更要求重选；只读取所选服务商 Key，缺 Key 引导配置。旧 BYOK 仅匹配有效目录时回显。更新需求与安装说明。
- 7 项 widget 测试通过，覆盖两工具、搜索选择保存、旧配置匹配、目录地址变化、空目录、缺 Key，并断言不存在手动输入框。修改页面和测试 scoped analyze 无问题，community 检查与 diff check 通过。未做真实 Key 调用、桌面人工视觉或 Windows/Release 验证。
## Claude 的 BeeBridge 模型列表（2026-11-03）

- macOS Debug 构建和最终 deep strict 签名校验通过，已重启社区版。
- 根因：目录默认 OpenAI 协议被当成服务商唯一协议。BeeBridge 增加显式附加 Anthropic 路径元数据，本地工具根据协议取得地址，Claude 同源根地址，Codex 保留 /v1；仅对内置地址匹配的配置映射，不猜自改地址。保留原选择器/手动填写/凭据绑定。
- 原 Bridge 默认生产 Claude 根地址与匿名 POST 实测一致：api.airick.cn/v1/messages 返回 401，猜测的 /anthropic/v1/messages 返回 404。未使用真实 Key 或推理请求，只证明接口路由存在。
- API 设置 5 项 widget 测试通过，覆盖 Codex 和 Claude 的选择、带入地址、读取正确 Key、手动改地址解除关联；新增 1 项真实打包目录映射测试覆盖两协议、自改地址/自定义服务商拒绝、原生 Anthropic 保留。两组 scoped analyze 无问题，community 检查与 diff check 通过。未验证所有模型真实调用、Windows/Release 或人工桌面视觉。
## API 设置复用聊天模型选择器（2026-11-03）

- macOS Debug 重新构建、最终 deep strict 签名校验通过，已重启社区版。
- 原 UiSelect 改为 AgentControlButton + ModelPickerEntry，保留原 API 表单、协议过滤、保存时读取 Key 和地址绑定。刷新仅更新模型目录，不重载/覆盖手动表单。需求先记录组件复用及验收。
- 本地工具设置 3 项 widget 测试通过，新增实际打开原 ModelPickerEntry、搜索并选择模型，再验证带入字段与保存；原改地址不误用 Key 回归通过。定向 analyze、community 检查及 diff check 通过。未做桌面人工视觉、Windows 和 Release 验证。
## 不使用钥匙串（2026-11-03）

- 原本地工具 API 设置 3 项 widget 回归通过，两个设置相关文件与共享包 6 文件定向 analyze 无问题。community 检查及 diff check 通过；macOS Debug 构建通过。
- 最终 deep strict 签名校验通过，已重启社区版。未代替用户重填真实 API Key；钥匙串弹窗的桌面人工验证留待重新保存后使用。
- 按用户明确选择改用本地明文文件：模型按 scope/provider 摘要文件名保存，Bridge BYOK 按工具单独保存；目录 0700、文件 0600、同目录临时写入原子替换。保留内存缓存与地址绑定。不调用旧钥匙串迁移或删除，旧 Key 需要重新输入。更新需求、ADR 0002、安装说明、README 和原设置提示。
- 本地工作区 Flutter 28 项通过，包含真实临时文件的权限、缓存清空后重开读取、删除、符号链接拒绝与偏好存储不含 Key；原模型配置/聊天回归通过。Go credential 测试与 vet 通过，包含真实文件重开、权限、链接、非法 account、地址绑定。
- 未使用或输出真实用户 Key，未做 Windows ACL/Release 验证。模型、Bridge 为独立文件，两者旧 Key 均需在原设置重新保存；原系统项保留不动。
## 回复不自动滚底（2026-11-03）

- 追加发送定位修正：本地首轮挂载和新问题落库后，使用原行 anchor 按 alignment=0 定位一次至顶部，随后仍停跟。定位别名追加在原消息 ID 之后，保留现有行 key。新增首轮/后续轮顶部坐标及后续回复 offset 不变回归；四组相关测试共 35 项通过。
- macOS Debug 构建与最终 deep strict 签名校验通过，已重启社区版。
- 原因：消息列表的短回复 ticker 跟随与新增消息 smartScroll 会主动改变阅读位置。通过 ChatSessionView 为本地会话关闭消息更新自动滚动，同时关闭输入框测量/窗口指标触发的被动回底；首次进入和手动回底保留。
- Flutter 定向测试 stream follow、detail scroll、scroll anchor、local entry 共 34 项通过，覆盖本地回复增长/完成/新增回答保持 offset、手动回底及共享默认行为。修改的 5 文件定向 flutter analyze 无问题；community 检查及 git diff --check 通过。
- 未改后端/运行时，未重跑 Go/Node；未做 Windows/Release 或桌面人工视觉验收。

## 输入框历史上下键（2026-11-03）

- 复用 PromptInput 的键盘处理，ChatSessionView 透传当前员工 SQLite 已发用户文本；空框 ↑ 最近/更早，↓ 更新/返回空草稿。手动编辑退出历史；非空草稿、输入法组合、修饰键、选区、附件与多富文本块不替换。历史回填不自动发送。
- `flutter test --no-pub --reporter expanded test/prompt_input_layout_test.dart test/rich_prompt_controller_test.dart test/local_workspace`：51 项通过。覆盖多行/边界/返回草稿、编辑退出、输入法/附件/修饰键和员工隔离，入口断言历史仅来自本地用户消息且透传至原输入框。
- 定向 `flutter analyze --no-pub` 检查输入框、ChatSessionView、本地页面及两项修改的测试文件：无问题。未做 Windows/Release 或真实桌面人工键盘验收。
- 增补首尾空格/换行原文保留后，输入框 14 项复跑通过；community 检查、git diff --check、macOS Debug 构建及最终 deep strict 签名检查通过，社区版已重启。

## 回复详情闪烁（2026-11-03）

- 原因：终态清理内存正文/工具时间线后，FutureBuilder 的新数据库查询仍 waiting，旧 pending 行被重新投影为空正文。按员工保存完整消息展示快照，waiting 时保留，done 时替换；时间线复制为不可变列表。异步视图按员工 key 隔离。原 ChatSessionView 与 ChatMessageList 不替换。
- 新增逐帧回归：注入流式正文和工具时间线，模拟落库及清理 overlay，检查刷新第一帧正文非空、消息列表 State 相同、新数据到达后显示最终正文。临时禁用快照保护，测试在 Expected non-empty / Actual empty 处失败；恢复修复后 local_workspace 全部 27 项通过。定向 flutter analyze 两文件无问题，check-community.py 和 git diff --check 通过。
- 未改运行时，本轮未重跑 Node/Go；未做 Windows/Release 与真实桌面人工视觉验收。构建与重启结果见本轮交付。
- macOS Debug 构建成功，最终 deep strict 签名校验通过，已重启社区版。仍有既有 Go bridge 最低 macOS 版本链接警告。

## 工具占位名与错误恢复（2026-11-03）

- 用户最新轮 12 次调用：10 次未知占位名、1 次 list_files 成功、1 次文件当目录失败。真实联调确认客户端出站工具名/schema 完整；模型间歇返回占位名或丢 MCP 前缀，未认定上游内部具体故障层。补充宿主实际工具目录（完整 MCP 名称和参数），社区提示不再引导未注册的搜索/桌面工具。中间版本真实联调仍发生短名错误，修正文字目录完整名称后最终 DSH+BeeBridge deepseek-flash 在临时自选目录完成 list_files→read_file，两次调用均成功、无失败、message.completed。未发送真实用户文件。
- Node 打包产物测试 9 项通过，包括真实 DSH/Codex 触发 ENOTDIR/不存在/目录当文件的明确失败后继续成功读取、技能、文件写入与命令允许/拒绝/取消。打包脚本测试 6 项通过。TypeScript 随 macOS Debug 构建编译通过，check-community.py 和 git diff --check 通过。
- 未修改 Flutter，本轮未重跑 Flutter 测试；未做 Windows/Release 或所有工具/模型实测。文字备份是对间歇模型工具识别问题的缓解，不能保证任意模型永不输出未知工具名。没有放宽 OS 隔离、审批或按占位编号映射操作。

## 提交前残留清理（2026-11-03）

移除已废弃的SkillIcon asset分支，恢复原网络图标/默认图标实现；旧数据库asset地址清理和技能ID兼容映射保留。生产包/tmp联调用例改为测试内生成包，持续验证完整资源进入runtime快照，不因缺少本机文件假通过。Bridge客户端还原11处纯空白改动，签名修复保留。需求、ADR和踩坑文档统一到私有明文凭据、Bus唯一广场、原文件附件和工具配置单一来源；历史验证记录保留。

28项Flutter定向测试通过（技能包安装/资源快照、Bus目录、原界面、本地Bridge），3文件定向analyze无问题；diff和社区检查通过。本轮不重复构建或真实服务商联调：生产代码仅恢复已无调用方的旧asset分支及收窄格式差异，未改变网络/工具/凭据流程。未创建Git提交。

## 悬浮提示文字居中（2026-11-03）

AppTheme Tooltip统一设置上下6/左右8内边距、1.4行高及even leading，沿用原颜色/圆角/组件。主题定向analyze无问题，macOS Debug构建通过、签名验证并重启。未新增低影响样式单元测试，未完成原生窗口截图视觉核对。

## Bus唯一技能广场（2026-11-03）

- 最终macOS Debug构建通过；清理增量产物中残留的local_skills后重新strict签名校验并重启社区客户端。最终旧图标迁移测试通过、定向analyze无问题。未进行原生窗口手工点选全流程；包安装/绑定与失败回退边界由定向测试覆盖。

- 移除local_skills目录、快照、PNG与pubspec资源声明，仅保留skill_id_aliases.json兼容旧绑定；不再自动种入本地技能，旧行保留给已有员工但隐藏广场，旧asset图标清为空走原默认图标。广场仅使用本次Bus响应ID/分类，失败清空投影，刷新聊天数据不恢复历史列表。
- 9项定向Flutter测试通过：全新无目录、v1升级保留消息与绑定、Bus成功/失败/空列表/控制器重开不回退、匿名接口、旧目录隐藏、安装重启/篡改恢复、原UI。6文件analyze无问题，真实匿名Bus返回success=true/total=81；社区检查与diff检查通过。

## 普通文件附件（2026-11-03）

- 最终macOS Debug构建与strict签名校验完成并重启社区客户端；最终附件4项测试再次通过。git diff --check与社区检查通过。

- 移除选择器与持久化扩展名限制，未知/无法解析格式保留原件；消息区沿用原卡片，未提取文字的附件由工具处理，文本模式提前拒绝并保留草稿。保存按SHA256检测源变化，工具导入既有隔离不变。
- 6项Flutter定向回归通过（附件提取/普通文件/持久化/同大小修改/超限/链接、工作区原UI拖入、控制器）；5个文件定向analyze无问题；Node二进制导入隔离测试1项通过。原生Finder手工拖入及各格式的真实工具解析未逐一测试，接收附件不代表已实现OCR/解压/转换。

## 间歇性模型 400 定位（2026-11-03）

- 后续反馈轮 8fd60e85-643a-4586-ae1f-606b6d91c254：read_conversation_history 成功后 model.tools_invalid；原日志没有 retry metadata，无法证明该历史轮是否重试。按其本轮内容及本地历史复现，在工具续轮再次观察到400，同一请求重发200。另4次真实最小请求得到：重试恢复、直接成功、连续两次400、重试恢复，不能承诺一次重试治愈。
- 增加每轮私有 model-diagnostics/<run>.jsonl，记录请求哈希、状态、尝试、稳定分类与格式白名单 requestId，无正文/参数/密钥；64条上限、0600、写失败不影响请求。定向5项测试和TypeScript编译通过，测试检查原样重试哈希一致且不包含工具结果/凭据。此轮不增加重试次数、不改模型/工具行为。
- 最终真实请求自然触发400：诊断 attempt=1/status=400/retryable=true，attempt=2/status=200，SSE DONE；macOS Debug 构建、strict签名验证和重启完成，git diff --check 与社区检查通过。未运行全量Flutter测试（本轮仅Node运行时诊断变更）；上游连续拒绝未解决。

- 截图对应 run d6e88ae2-b1bf-4387-b6ec-0ee47af9c230，deepseek-flash，首请求失败、无工具事件；附件私有副本存在。日志只有安全分类，不能追溯该轮原始服务商正文。
- 真实 DSH + BeeBridge：list_files/read_file 均成功，第三个模型请求 HTTP 400；另一轮首请求也 400，平台 `bad_response_status_code` / `Request body format invalid`，同一请求体原样再发 HTTP 200，去 tools/只保留读取工具亦 200。原截图消息重新提交未稳定复现；不存在已证实的固定 PDF/字段错误。
- TypeScript 编译通过；5 项定向 Node 测试通过（真实注册目录、office schema、错误分类脱敏、严格限定的一次原样重试/持续失败/取消/其他服务商/普通400/成功不重试、模型代理边界）。macOS Debug 构建通过。ESLint 未完成：仓库缺 eslint.config，ESLint 9 无可用配置；未新建无关 lint 配置。
- 单次重试不能保证上游连续异常时成功；不禁用工具或扩大文件权限。
- 恢复路径联调：注入第一次已识别400，第二次发送真实 BeeBridge deepseek-flash，最终 HTTP 200 并收到 SSE DONE；也观察到第二次真实请求仍400，确认最多两次后正常失败。此项是注入拒绝验证，区别于上述自然发生400后的原样重发证据。最终社区 Debug 签名验证并重启。

## 模型 400 与工作目录（2026-11-03）

- 本地 ledger 确认失败轮 model.upstream_failure，未产生工具调用；员工配置和 workspaces.json 的自选目录一致。BeeBridge/deepseek-v4.1-flash 普通请求 200，完整工具请求 400，逐项定位 office_create 的 sheets.name.pattern；只补左方括号转义后完整工具请求 200。最终构建产物导出的真实 schema 带完整工具、流式请求再次返回 200、SSE 且收到 DONE。诊断不输出密钥、聊天历史或原始服务商错误正文。
- 社区边界把有界上游 error 转换成稳定错误码，保留 HTTP 状态；商业 Bus 默认解析行为不变。27 项 local_workspace Flutter 测试通过，修改文件 flutter analyze 无问题。
- 打包产物执行 Node 测试 8 项通过：工作表合法值/禁用字符、401/429/500/工具参数错误脱敏、重定向防泄漏、真实 DSH/Codex 在自选目录读取附件/技能、写文件、shell 允许/拒绝/取消及目录持久化。
- flutter build macos --debug --no-pub 成功，包含 TypeScript 编译；最终 deep strict 签名检查、check-community.py 与 git diff --check 通过。仍有既有 Go bridge macOS 13 对最低 12 的链接警告。未做 Windows/Release、所有服务商或用户会话人工重发验收。仓库没有 scripts/check-repo-hygiene.sh，使用公开版 community 检查。

## 正式桌面客户端技能目录同步

已打开 /Applications/知办AI.app 1.5.5，确认当前登录技能广场。使用其当前会话仅 GET 客户端 /skills 与 /skill-categories：共 86 项，平台 81、企业 5。未安装线上技能、创建员工或修改绑定。官网无登录展示仅 81 项且缺示例，不能替代正式客户端数据。

社区资产补齐 81 项真实 code/版本/80 个使用示例，catalog.json 沿用稳定本地 ID；client-catalog.json 保存脱敏的平台字段，snapshot.json 保存 SHA256。81 行与正式响应逐字段一致；完整账号可见 86 行导出保存在仓库外的本机目录，不随社区版发行，不含认证信息或签名 URL。

flutter test --no-pub test/local_workspace/local_skill_catalog_test.dart：3 项通过，含唯一 code、示例一致性、离线图标、数据库升级；相关测试 flutter analyze 无问题。macOS Debug 构建成功。python3 .github/scripts/check-community.py .、git diff --check 通过。

限制：列表中没有 SKILL.md、执行包或包下载地址；现有客户端详情旧接口返回 404。未将简介/示例作为执行指令，未通过修改线上绑定、管理接口或读取其他租户数据获取包，未声称完成技能包迁移。

## 免登录本地开发工具与数字员工执行

- 文档：requirements/local-workspace、ADR 0002、INSTALL 更新入口、协议、目录、凭据与审批边界；pitfalls/community-local-tools 记录 ESM 路径、broker origin、Responses namespace、快照和进程清理问题。
- 原头像菜单和原 LocalCodingToolsPage 接入本地路由，无 SessionLayout；沿用现有 Bridge BYOK、安装、配置备份和恢复，不增加设备注册。原创建表单开放引擎选择并回显，模型继续只在对话选；工作目录用原 AgentControlButton 与系统选择器。自动任务继续要求登录。
- 独立 desktop/community.ts 复用原引擎、broker、文件/Office 工具和 policy/supervisor。父进程管道传凭据，模型直连用户上游；隔离和原审批保持。SQLite v6 工具 timeline 与输出快照本地保留，原消息组件预览。
- TypeScript：锁定 Node 24.19.0 与 TypeScript 编译完整 src 成功。node --test test/community-runtime.test.mjs，5 项通过；额外用最终 macOS 包内 runtime 重跑，同样 5 项通过。模型响应使用本机模拟上游，但 Harness、Codex、broker、系统隔离、文件/命令均真实执行。验证 write/read、shell 批准/拒绝/停止、真实文件内容、输出快照、无登录产品服务、禁止重定向/非本地 HTTP/模型与协议错配。
- Flutter：本地工作区 19 项、桌面 shell 1 项通过，新增菜单导航不加载账号、引擎可选/回显、timeline 重开保留；修改范围 analyze 无问题。
- Go：go test ./internal/credential ./internal/rpc ./internal/configuration 全通过。
- python3 .github/scripts/check-community.py . 与 git diff --check 通过。macOS Debug 构建成功；已有 Go macOS 13→12 链接警告仍存在。
- 未验证：真实付费服务商 Key、Windows、人工逐像素 UI，以及替用户执行全局工具安装/配置改写；本轮未覆盖用户的既有工具配置。Google 原生模型不提供工具执行，Codex 上游必须支持 Responses。原仓库无 scripts/check-repo-hygiene.sh，使用其现有 community 检查。

## 全页面原组件复用核对

本轮没有新增 Widget 类、组件文件或视觉资产。数字员工和技能相关的简化布局改回既有业务组件；模型图标/平台信息从原控件提取为共享函数，原入口继续调用同一实现。

| 区域 | 结果 | 验证 |
|---|---|---|
| 侧栏、头像下拉、设置入口 | verified：沿用原组件、折叠行为；底部不显示设置 | App shell 1 项测试通过，无账号请求 |
| 消息列表、聊天、历史、输入框 | verified：沿用现有组件、空态位置与本地消息 | 本地页面回归；无员工时保留本地创建/配置操作 |
| 数字员工列表 | verified：原 Gallery、来源 Tab、添加更多、原搜索、网格 | 900/1200px 单卡、多卡坐标；官方/我的切换 |
| 员工详情、创建/编辑 | verified：原详情弹框进入聊天；原完整表单；创建不选模型 | 原组件类型、字段/校验、编辑回显、对话选模型持久化 |
| 删除确认 | changed with reason：原 showUiConfirmDialog，提示本地消息级联删除 | 代码核对；本轮未操作真实用户数据 |
| 技能广场与我的技能 | verified：原筛选、Tab、卡片与聚合列表 | 搜索、分类、移除回归 |
| 技能详情与添加目标 | verified：原 SkillDetailDialog/SkillInstallAgentDialog | 缺包说明、添加后使用、跳转对话；本地头像不走网络 |
| 聊天模型菜单 | verified：原 AgentControlButton/ModelPickerEntry、440px 菜单及原图标函数 | 实际弹出/选择、文本模型过滤、按员工保存 |
| 自动任务、云盘、通讯录 | changed with reason：未登录不可用；使用对应模块现有反馈组件 | 三页登录提示与零网络断言；不渲染依赖账号的完整数据页面 |
| 模型服务、设置 | verified：继续原页面与服务商顺序 | 设置进入模型服务、Key 自动启用测试 |
| 全桌面逐像素对比、Windows、真实 API Key | not verified | 本轮无桌面交互工具；未使用用户密钥、未提供 Windows 环境 |

验证命令：
- packages/zhiban-client：flutter test --no-pub test/local_workspace test/digital_employee_gallery_layout_test.dart，15 项通过。
- apps/zhiban-app：flutter test --no-pub test/local_workspace_shell_test.dart，1 项通过。
- 修改范围 flutter analyze（含页面回归用例）：No issues found。
- python3 .github/scripts/check-community.py .、git diff --check：通过。

macOS：flutter build macos --debug --no-pub 成功，已结束旧社区版进程并打开本轮构建产物，确认新进程运行。

页面测试拒绝所有 HttpClient 创建，覆盖上述本地入口后请求数为 0。没有重新运行全仓商业模式测试；已知旧断言差异见下文及 pitfalls。

## 模型入口按用户修正移到对话

本节取代下文“数字员工选择聊天模型”的创建表单方案。CreateAgentEditor 已移除模型字段，LocalWorkspacePage 创建/编辑不再读取模型配置或要求配置完成，编辑保留既有选择。对话 PromptInput.runtimeControls 注入 LocalChatModelControl，复用 AgentControlButton/ModelPickerEntry；仅使用本地服务商列表，选择按员工持久保存，生成中禁用切换，未选择发送提示。

页面测试覆盖创建无模型字段、新员工模型为空、对话原选择器切换到第二模型、向量模型过滤、其他员工模型不受影响和零后端请求。创建/编辑及原布局回归同跑。弹出 ModelPickerEntry 必须像原组件一样指定菜单宽度，否则 ListView 会因 intrinsic width 布局失败；已通过实际点击弹框回归。

未使用真实 Key 请求模型，未验证 Windows。

- flutter test --no-pub test/local_workspace：11 项通过；修改范围 flutter analyze 无问题，community 检查及 git diff --check 通过。
- macOS Debug 最终构建成功，已重新打开社区版，模型按钮位于对话输入框。

## 数字员工选择聊天模型

- 原 CreateAgentEditor 运行配置增加聊天模型 UiSelect，按服务商分组，仅列已启用服务商的已启用文本模型；新建默认第一项，编辑回显已保存项，原模型不可用时需重新选。选择用 provider_id/model_id 联合标识，本地提交不再覆盖为默认模型。原表单其他字段和服务端入口保持不变。
- flutter test --no-pub test/local_workspace/local_workspace_entry_test.dart test/local_workspace/local_workspace_store_test.dart test/local_workspace/local_workspace_controller_test.dart：3 项通过，覆盖下拉选择第二模型、过滤向量模型、保存、编辑回显、本地持久化和发送逻辑回归，页面无后端网络请求。
- 修改范围 flutter analyze、git diff --check、community 材料检查通过；未进行真实 API Key 联调或 Windows 验收。
- 发送控制器专项增加实际 provider/model 参数断言并通过；macOS Debug 构建成功，重新打开客户端供用户选择模型。

## 单员工卡片排列修复

- 本地数字员工列表撑满横向空间且左上对齐，恢复原版 12px 卡片区边距/间距和按最小卡宽 292px 自适应列数；卡宽计算复用原 gallery 的生产入口，已有测试入口保留。未改员工数据或卡片内容。
- 本地工作区页面测试通过，增加 900/1200px 窗口单卡片坐标/宽度、两卡片同排/间距断言，同时保留创建/编辑/技能/聊天回归；修改范围静态分析、git diff --check 与 community 检查通过。
- 未做 Windows 或桌面人工视觉验收。
- 原数字员工布局测试 flutter test --no-pub test/digital_employee_gallery_layout_test.dart：4 项通过。
- macOS Debug 构建成功，重新启动社区版供用户查看。

## 创建/编辑数字员工恢复原版表单

- 移除本地简化表单，直接复用 CreateAgentDialog/CreateAgentEditor 的头像、名称、职责、人设、技能、应用、知识库、欢迎语、标签、运行位置/本地引擎、备注、校验、固定底部按钮和原布局。技能复用原 SkillPickerDialog，注入本地可执行项目；账号能力提示登录且不调用后端。
- SQLite schema v3 增加 employees.metadata；原文件名及员工/聊天/绑定保留。职责、人设、欢迎语、标签、备注、头像、运行信息保存本地，编辑回显；主要职责投影卡片，欢迎语投影聊天空态，人设为空时按名称/职责生成模型提示。头像复制到应用支持目录 community_avatars，AgentAvatar 支持本地文件。
- flutter test --no-pub test/local_workspace test/prompt_input_layout_test.dart：23 项通过。涵盖原表单/字段、必填验证、原技能选择器、不可执行技能不出现、创建保存、编辑回显、metadata 重启保留、旧数据库升级和本地操作不请求网络。
- flutter analyze --no-pub（本地工作区、创建表单、技能选择器、头像及本地测试）：无问题。git diff --check、community 材料检查通过。
- 未做系统文件选择器头像人工验收、Windows 构建或真实 API Key 聊天；云端、应用、知识库与工具引擎仍按本地模式契约受限。
- macOS Debug 最终构建通过，重新打开社区版供用户查看原表单。

## API Key 保存与自动启用修复

- 修复 ModelServiceStore 的 macOS 安全存储选项，统一读/写/删除/旧明文迁移使用系统登录钥匙串。ModelProvidersNotifier 保存非空 Key 后启用服务商与首个文本模型，保留顺序；模型发现异常不使成功保存误报失败。
- 相同 Debug entitlements 临时签名的 Swift 原生测试：数据保护钥匙串写入返回 -34018，登录钥匙串写入/读回/删除均返回 0。另直接复用当前插件 Swift 实现验证，write/read/delete 全为 0，读回值匹配；测试凭据已删除，没有读取真实 Key。
- flutter test --no-pub test/local_workspace test/pages/model_service/provider_key_switch_test.dart：12 项通过，覆盖 Key 安全迁移、自动启用、已有关闭模型恢复、发现异常下保存不丢失、顺序保持、切换服务商不误存旧 Key，以及本地工作区回归。
- flutter analyze --no-pub（修改的存储、Provider、测试）：无问题；git diff --check 与 community 材料检查通过。
- 未使用真实 Key 请求模型，未验证 Windows 原生凭据库；原生验证针对独立测试进程与当前插件实现，实际 UI 保存仍需用户重试。
- macOS Debug 构建成功，重新启动社区版供用户验证；原有 Go bridge 最低 macOS 版本链接警告仍存在。

## 完整技能目录及底部入口修正

- 本地目录恢复为 149 项（144 项目录元数据、5 项可执行文本技能），四分类及名称/描述/code 搜索沿用原广场组件；缺少执行包的卡片显示“需技能包”，详情可滚动，添加入口和员工编辑均阻止绑定。左下角额外设置入口已删除，头像菜单设置保留。
- SQLite schema v2 自动升级，原数据库文件名保持不变；启动同步内置目录，不清除员工、聊天或绑定。来源及元数据快照 SHA-256 记录在 assets/local_skills/README.md；未复制第三方执行包。
- zhiban-client：flutter test --no-pub test/local_workspace test/prompt_input_layout_test.dart，22 项通过。新增完整目录计数/唯一性/分类/可执行边界、v1 升级及再次打开的数据保留、分类与 code 搜索、目录详情及禁止绑定验证。页面测试禁用网络且请求数为 0。
- zhiban-app 本地侧栏测试 1 项通过；两项目修改范围静态分析无问题；community 材料检查和 git diff --check 通过。
- 未验证真实 API Key、Windows 或缺失技能包的执行；本次恢复目录不代表 144 项工具技能已具备本地执行能力。
- 本次 macOS Debug 构建成功，已重启社区版；现有 Go bridge macOS 13/12 链接版本警告仍存在。

变更范围：桌面本地入口、SQLite 员工/消息/技能仓库、文本技能资产、模型直连、现有模型配置自动启用及凭据安全存储、macOS 打包缓存校验。未登录自动任务不开放。

## 已通过

- zhiban-client：flutter analyze --no-pub（本地工作区、修改的模型配置文件、相关新增测试），无问题。
- zhiban-app：flutter analyze --no-pub lib/main_desktop.dart，无问题。
- flutter test --no-pub test/local_workspace test/pages/model_service/provider_key_switch_test.dart test/pages/model_service/services/provider_model_fetcher_test.dart：14 项通过。包括 SQLite 重启持久化/中断恢复/级联删除、技能与历史传递、三协议回复提取、标准 /v1 路径、错误脱敏、Key 迁移与模型自动启用、禁用网络的页面导航。
- python3 apps/zhiban-app/scripts/test_local_agent_bundle.py：6 项通过。
- python3 .github/scripts/check-community.py .、git diff --check：通过。
- macOS Debug 构建：最终代码构建通过，产物为 apps/zhiban-app/build/macos/Build/Products/Debug/知办AI.app。仍有现有 Go bridge 最低 macOS 版本链接警告（13.0 对 12.0），未在旧系统验收。

## 现有测试失败与未验证

扩大运行 test/pages/model_service：39 项通过，4 项失败。1 项旧目录地址断言与当前资产不符；3 项商业托管密钥测试与公开树固定 communityEdition=true 不符，详见 pitfalls/local-workspace-validation.md。本次不修改这些商业契约测试或目录地址。

没有用户真实 API Key，未向任何真实模型服务发送付费请求；协议使用模拟 HTTP 适配器验证。未进行 Windows 打包、签名发布或桌面人工交互验收。当前聊天为完整文本回复，不包含流式增量或工具调用。

构建修复：打包脚本检查 TypeScript 文件而非只信任 .complete；本机 Go vendor 按安装文档重新生成（默认 Go 代理超时，改用 goproxy.cn 下载，版本仍由 go.sum 校验）。vendor 未提交。

## UI 保留修正

用户要求整体 UI 沿用原版。已移除本地工作区独立简化导航，桌面通过 MainLayout(localWorkspace: true) 复用 DesktopSidebar，原导航顺序/SVG/渐变/180px 与 64px 折叠保留。MainLayout 本地分支不构建 SessionLayout。

聊天复用 ConversationListHeader/ConversationListPanel、ChatDetailHeader、ChatSessionView/PromptInput/消息气泡及 ChatHistoryPanel；历史面板本地注入消息，跳过服务端 reload，支持过滤与定位。员工/技能复用 AgentCard/SkillCard；设置复用 SettingsPage 的原分组与卡片，本地分支不读取 accountInfoProvider。应用、云盘、通讯录及自动任务的账号依赖操作提示使用条件。

- zhiban-client：flutter test --no-pub test/local_workspace test/prompt_input_layout_test.dart，20 项通过。覆盖原卡片和输入框出现、本地消息进入会话、历史面板、设置模型入口，禁用网络时请求计数为 0。
- zhiban-app：flutter test --no-pub test/local_workspace_shell_test.dart，1 项通过。验证原侧栏顺序、展开/折叠、导航和设置入口；账号 Provider 设置为抛错以确认没有加载。
- 两个子项目修改范围 flutter analyze --no-pub 均无问题；community 检查及 git diff --check 通过。
- macOS Debug 最终构建通过（包含路由无过渡修正），并重新启动恢复原 UI 的社区版。尚未做真实模型 Key 联调或 Windows 人工验收。

## 头像、技能组件及会话空态修正

- 头像复用 SidebarUserTop / SidebarProfilePopover 的原锚定菜单，支持点击外部关闭和设置跳转，本地分支不读取账号或 auth/me。
- 技能复用原 UiSegmentedTabs、SkillsFiltersBar、SkillsContent 和 MySkillsView；纯展示部分提取到共享包，原 App 路径保留 export。我的技能支持本地使用/确认移除。打包技能没有更新时间/下载热度，仅提供默认排序。
- 会话列表通过最小视口高度约束使空态整体垂直居中，搜索无匹配的布局坐标断言通过。
- 客户端 20 项测试通过；桌面扩展回归 16 项通过、2 项旧断言失败（计费组件在社区版原本隐藏、自己的名片原本不显示无回调操作区），详见 pitfalls。两子项目修改范围静态分析无问题。测试验证本地操作无后端请求。

- 本次 macOS Debug 构建通过，已重新启动；本地侧栏专项测试单独运行 1 项通过。未做真实 API Key 联调或 Windows 验收。

## 本地附件（2026-11-02）

- 共享包：flutter test --no-pub --reporter expanded test/local_workspace，14 项通过；涵盖 DOCX/XLSX/UTF-8 提取，空/超长/二进制/实体拒绝，文件大小与符号链接限制，附件独立发送与持久副本、源删除后可读、删除员工清理、历史文本进入模型而路径不出站。原组件测试新增原文件入口添加/移除和缺少 Key 时草稿保留，无产品网络。
- 桌面：flutter test --no-pub --reporter expanded test/local_workspace_shell_test.dart test/attachment_preview_panel_test.dart，12 项通过；原预览开关、宽度布局、本地读取及网络权限边界。
- scoped flutter analyze：本地工作区、共享预览 Host 和本地测试，无问题。
- macOS PDFKit：临时 Swift 程序用 Core Graphics 生成含文字层 PDF，重新加载后提取 amount 200 通过；原生通道编译通过。没有用真实用户文件或 Key 测试外部模型；尚未手工点击完整的 PDF 附件发送流程。
- macOS debug 构建通过并重启；check-community.py 与 git diff --check 通过。未运行 Windows/Linux 构建；PDF 目前仅 macOS 可提取。未运行全仓测试（本轮为共享客户端/桌面局部改动）。

## 钥匙串重复授权修复（2026-11-02）

- ModelServiceStore 增加按完整 key 的进程内缓存与并发读取合并，底层安全存储可注入测试替身；保存成功写入缓存，删除/失败失效，晚到读取不覆盖新值。
- flutter test --no-pub --reporter expanded test/local_workspace：18 项通过，新增 4 项缓存回归（跨实例重复/并发只读一次、保存无需读回、替换/删除、异常重试及旧读取失效）。原聊天、附件、模型配置测试通过。
- flutter analyze lib/pages/model_service/services/model_service_store.dart test/local_workspace/model_key_cache_test.dart：通过。check-community.py 和 git diff --check 通过。
- macOS debug 重新构建后重启；不读取或输出真实密钥，未代替用户操作系统授权框。系统弹窗是否消失仍须用户首次授权后连续发送消息验证；重启/重新签名后的首次授权属于系统行为。

## 回复状态与附件闪烁（2026-11-02）

- 原因：临时 busy/解析误用 composerEnabled，触发原“员工已删除”说明并卸载输入框；局部 setState 每次新建消息查询 Future。
- 修复：保留可编辑会话，使用 sendReady/isSending；消息按 controller.dataRevision 缓存 Future；pending 气泡使用创建时间作为 streamStartedAt。
- flutter test --no-pub --reporter expanded test/local_workspace：18 项通过，原页面回归扩充附件前后 PromptInput State 相同、模型请求 pending 时输入框仍在/停止按钮显示/无删除提示、停止后 interrupted 与停止按钮移除。原模型/密钥/文件回归通过。
- scoped flutter analyze 本地工作区与入口回归通过；macOS debug 构建并重启。未进行真实 API 服务商交互与系统文件选择器的手动视觉验收。

## 官网技能目录对齐（2026-11-02）

- 来源：https://www.zbwork.cn/ 与公开 https://www.zbwork.cn/api/public/v1/skills/showcase，81 项。逐项比对名称/描述/使用人数完全一致，分类和来源直接映射；79 个 PNG 图标本地打包，不保存签名 URL。原技能卡片增加资产图标分支，保留网络图默认行为。
- SQLite v5 保存展示字段、启动清理旧不可执行目录；5 项旧本地文本技能保留兼容已有绑定，广场只展示新 81 项，最热按快照人数排序。
- flutter test --no-pub --reporter expanded test/local_workspace：18 项通过；新增图标 widget 检查后，定向 local_skill_catalog_test.dart 3 项通过，含真实资产可加载和旧数据库升级/重开保留绑定及聊天。
- scoped flutter analyze 本地工作区、SkillIcon、目录回归：无问题。check-community.py、git diff --check 通过。macOS debug 构建通过，重启新应用。
- 限制：公开展示接口没有技能包/线上 code/版本/示例，未恢复这些内容，不声明 81 项可执行。未手工逐卡像素核验/Windows 构建。线上同分项目排序可能随接口顺序不同；本地同分保持公开源顺序。使用人数不是实时更新。

## 服务器技能列表（2026-11-02）

- 新增独立匿名 `/api/public/v1/skills` 读取与 SQLite 缓存；原列表/分类/卡片/详情组件复用，服务器目录覆盖广场，原绑定保留。
- Flutter scoped analyze 无问题；local_workspace 20 项非 UI 测试通过。原 UI 测试按新契约增加“聊天无请求、广场只请求一次公开目录且失败回退”断言，单独重跑通过（共 21 项）。
- `flutter build macos --debug --no-pub` 成功，社区版已重启；生产客户端未操作。Flutter SDK 自动更新检查曾网络失败，现有 SDK 分析/测试/构建成功。
- 完整版后端 Go 技能服务/public/admin 测试、定向 vet、Bus 编译通过。未部署生产或进行生产目录联调，线上新路由可用后才会实时同步。

## 本地 Bridge 签名校验（2026-11-02）

根因：社区 Debug helper 为 ad-hoc，客户端原本要求商业 Developer ID。调整仅限社区非 Release：仍严格验证 bundle seal、identifier 和既有 bundle 内路径；Release 继续正式证书校验。Bridge 客户端 21 项测试通过（含完整 ad-hoc 接受、强制发行校验拒绝和篡改拒绝），定向 analyze 无问题。真实打包 helper 的 strict/identifier codesign 均通过，initialize 与 byok.settings 只读 RPC 均成功；未输出设置值或密钥。未测试真实服务商调用与发行公证。

## 本地工具 API 设置带入模型配置

复用 UiSelect 与 ModelServiceStore，选择协议匹配的启用文本模型时带入地址/模型，保存时才读所选 Key（不回显），手动改地址解除密钥关联。原 Bridge 配置和手动输入保留。定向 analyze 无问题；2 项对话框测试通过，覆盖带入保存和改地址不误用 Key；Flutter 资产缓存跨用例时须清理 rootBundle，避免未完成资产 Future 留在前一个测试 zone。macOS Debug 构建和最终 deep strict 签名验证通过，社区版已重启。未做真实服务商调用；Responses 兼容需实际检测。

## 公开技能包完整安装（2026-11-03）

### Review 五项修复验证

- 客户端和 Bridge 双层约束 API 地址与 Key；3 项 API 设置 widget 测试通过，覆盖新配置导入、导入后改地址、已有配置改地址。Go credential 包测试通过，覆盖同地址保留、改地址空 Key 拒绝且不改原值、显式新 Key 保存。
- 本地工作区 27 项 Flutter 测试通过：超限不触发接受回调且不落消息；有界历史保留最近消息；原技能弹框损坏包“重新安装→使用”；删除清理运行与附件且其他文件保留。两组 scoped analyze 无问题。
- macOS 打包 TypeScript 编译通过；最终包执行 6 项 Node 测试通过：真实 DSH/Codex 可读取导入原附件与技能资源、12 万字符单条消息、允许/拒绝/取消；附件导入拒绝跨员工、错误摘要、链接并保留源文件。
- macOS Debug 重建、最终 deep strict 签名检查、check-community.py 与 git diff --check 通过。未验证真实付费服务商调用、Windows 和 Release 公证；模型本身的上下文窗口仍可能低于传输上限。

- 已部署公开目录匿名返回 81 条；逐项下载 81 个版本包，全部 ZIP CRC 与 SKILL.md 检查通过。单技能 export 真实包用于安装回归，验证完整资源落盘、SQLite 指令、运行快照逐文件一致。
- 安装回归覆盖 SHA 不符、路径穿越、并发一次下载、安装 Future 完成、数据库重开保留指令、篡改拒绝、重新下载恢复、已安装复用不下载。原页面回归保留原添加/使用弹框和会话入口。
- 本地工作区 Flutter 24 项测试通过，定向 analyze 无问题。macOS Debug 构建同时编译 TypeScript runtime。DSH/Codex 5 项真实执行器测试通过；模型 mock 触发 read_skill_file，实际读取完整包的 references/data.txt，原文件/命令允许、拒绝、取消行为通过。
- 更新需求、安装说明、UI 复用规范和 Future 自等待/规范路径踩坑。未验证全部 81 个技能的业务输出、真实付费模型调用、外部依赖、Windows 构建和 Release 公证。
- 最终 macOS Debug 重建成功，App.framework 与主 App 重新签名后 deep strict 验证通过，已重启社区版；check-community.py 与 git diff --check 通过。
