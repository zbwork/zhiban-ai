# 社区版本地工作区

## 首次对话引导（2026-11-06）

未选择数字员工时，将原聊天插画、标题、说明和操作放在同一个居中的引导区，使用横向留白并允许说明换行。标题为“从第一位数字员工开始”，说明为“让它帮你写作、整理资料，或处理日常工作。”；主操作“创建数字员工”打开原创建窗口，次操作“模型服务设置”进入原模型服务页面。不把模型配置描述为创建员工的前置条件。左侧会话列表与已有会话保持原行为。

行业做法与适配判断：参考 [Carbon 空状态规范](https://www.carbondesignsystem.com/building-blocks/core/patterns/empty-states)，采用积极简短的标题、用途说明，以及紧邻说明的主操作；适配现有居中插画和 Flutter 按钮，不引入独立引导流程。复用 ChatEmptyState 的可选标题与操作区，未传新参数的页面保持原样。

验收：首次进入对话页时，插画、文案和按钮连续展示，不再将操作固定在底部；两个入口仍到达原目的页面；已有聊天空状态不变；窗口缩小时文案可换行。

## 上游本地执行修复适配（2026-11-05）

对照 EasyO 的 7b5638d25 与 2e14c05de：社区 helper 同样复用 Codex transport 和 DesktopBroker，需要限制祖先项目配置发现，并兼容 Responses 默认工具选择；共享模型错误格式化保留白名单 model.* 错误码及规范 HTTP 状态，不展示服务商任意正文。

- Codex 启动参数强制追加 `project_root_markers=[]`，配置发现停止在隔离 cwd，不读取真实用户配置、不扩大沙箱白名单。
- Broker 仅在 Responses 中省略 `tool_choice: "auto"`；保留 none、required、指定工具及其他协议的原请求。
- 实时与历史错误使用同一固定文案和稳定模型错误码，敏感正文仍过滤。

适配判断：采用上游已定位、已验证的最小修复。行业依据沿用上游调研的 [项目根发现规则](https://developers.openai.com/codex/config-advanced/#project-root-detection) 与 [Responses 创建接口](https://platform.openai.com/docs/api-reference/responses/create) 默认工具选择语义；本次是同实现缺陷回移，不声称重新核验在线文档。社区当前为每轮 helper、BYOK 直连；不引入商业余额快照、登录通道重连或服务端就绪流程。

验收：用户目录祖先场景中真实 Codex 能完成本地文件工具往返；默认及显式工具策略逐项验证；模型错误码与 HTTP 状态展示且不泄漏原始详情；文件审批、拒绝、取消和现有模型选择保持。

## 本地执行顶栏提示（2026-11-05）

社区聊天顶栏保留本地图标和标记，悬浮提示为“本地执行，发送消息时自动启动”。该提示说明执行方式，不代表组件已就绪或任务已成功；不得读取服务端 LocalAgentService 的常驻连接状态来判断社区 helper。组件缺失、模型协议不兼容等错误仍由发送流程报告。服务端模式保留原已连接/未连接状态，已删除员工保留删除提示。通过共享顶栏的显式能力参数区分两种执行方式，默认服务端行为。

验收：社区空闲时不显示未连接；本地图标不随服务端连接状态变化；服务端模式的连接状态与员工删除提示保持原行为。

## 本地聊天访问权限（2026-11-04）

社区聊天复用原权限菜单、AgentControlButton、AgentMenuRow 与 FullLocalAccessDialog，提供请求批准/帮我批准/完全访问。未登录可用，回复期间禁止修改。默认帮我批准；普通模式按员工本地保存，完全访问仅在当前客户端控制器生命周期有效，重启恢复帮我批准，不写入持久配置。切换员工不串权限，改目录不重置权限。

运行入口显式传递模式并校验枚举；完全访问通过现有 App-only broker 确认凭证选择工作区后运行。复用 LocalPolicy：ask 允许工作目录读取，写入/命令/网络等询问；assist 允许常规新建写入，其余风险操作询问；full 仍不代替上传单次批准和系统管理员授权。拒绝、取消保持原行为。

行业最佳实践与适配性：参考 https://developers.openai.com/codex/security/ 的执行隔离与审批分离原则（本次访问返回 Forbidden，具体行为依据仓库已有 LocalPolicy 与执行器回归，不声称核验了在线最新版）；adopt 显式授权、默认受限和高权限确认，adapt 到现有社区父进程管道及 broker；reject 持久化完全访问和仅改变菜单但执行固定 assist。验收：三档菜单、确认取消、员工隔离、普通权限持久化、完全访问重启降级；真实执行器 ask 写入询问、assist 常规写入自动、full 命令自动而上传仍询问；保留目录、模型、停止与拒绝行为。

## 未登录入口可见性

创建与编辑数字员工共用原表单，本地模式隐藏应用、知识库装配与云端运行位置；保留核心技能和本地引擎。服务端模式保留原字段，不删除已保存元数据。

设置页在本地模式隐藏个人资料卡、账号与安全、支持与服务区块（包括编辑资料、更换头像、基础资料、登录状态、账号安全、分享给朋友、联系客服、清除缓存、关于我们）；保留模型服务和本地运行，头像菜单隐藏检查更新。服务端模式保持原样。

本地工作区开放本地自动任务（见 [本地定时任务](local-scheduled-tasks.md)），隐藏云盘、通讯录主导航，以及帮助与客服、检查更新、发起群聊、输入框云盘/应用/通话/会议入口；保留本地对话、数字员工、技能广场、模型服务、本地开发工具、文件、表情和聊天历史。服务端授权壳层保留原入口及原权限判断。以当前壳层是否为本地模式区分能力，不能用残留 token 判断登录；本轮不新增服务配置或登录流程。隐藏只是界面可见性，不代替后端鉴权。复用原组件，通过可选能力参数控制，默认保留服务端行为。验收：本地无受限入口、原可用入口保留、默认服务端组件入口保持。

## 模型服务获取密钥入口

在原模型服务详情的“API 密钥”标题后展示“获取密钥”文字链接，文字显式使用 Theme.primaryColor 品牌蓝（页面局部 colorScheme.primary 为中性色），无按钮背景、边框和额外内边距，保留键盘焦点与点击语义。使用当前内置服务商目录中显式配置的官网/开放平台地址，通过系统浏览器打开。不从 API 地址猜测官网，不携带密钥或用户输入；自定义服务商没有官网元数据时隐藏入口。保留原官方文档入口。沿用 Flutter TextButton 与现有 url_launcher 外部打开方式，打开失败使用原 Toast。验收包含草稿/已保存服务商切换、缺少官网和打开失败。

## 技能广场仅使用 Bus

技能广场列表、分类、图标仅来自匿名 Bus GET /api/public/v1/skills。进入广场及刷新时请求，加载沿用原组件，失败显示原错误和刷新入口，不展示本地快照或旧请求缓存。删除随包目录、介绍、图标和本地分类。已安装技能包、员工绑定及我的技能仍保留本地；仅保留code到旧ID的最小兼容映射，不用作目录。SQLite历史目录留作安装与绑定元数据，不作为广场展示源；启动时隐藏旧listed记录。

行业实践与适配性：adopt Bus服务端目录为唯一来源，原匿名客户端、技能安装摘要验证及组件继续复用；adapt Flutter异步加载/错误状态（https://docs.flutter.dev/cookbook/networking/fetch-data）。用户明确不需要本地目录，reject离线快照和缓存回退。验收：全新/旧库离线广场均不显示旧目录，Bus返回空则空、失败可刷新，旧员工与已安装技能保留，发行包无local_skills图片。

## 普通文件附件

点击选择与拖入均允许任意扩展名及无扩展名的普通文件，沿用原附件卡片/预览，不新增组件。原文本、DOCX/XLSX、macOS PDF 解析仍保留；不支持、损坏、加密、空内容或提取超限时仅保留原文件，不向模型伪造文本。未提取文字时明确提示模型使用本轮工作目录中的附件相对路径，由现有工具能力决定能否处理；不新增OCR、任意格式预览或自动解压/执行。仅文本模式拒绝发送需工具处理的附件并保留草稿。

仍最多5个、单项10MiB；提取文本单项60000/总计120000。原文件以SHA-256检测选择后变化，拒绝符号链接/目录，随机文件名持久化后仍经原摘要验证导入工作目录，工具审批不变。

行业最佳实践与适配性：参考 file_selector openFiles 官方文档（https://pub.dev/documentation/file_selector/latest/file_selector/openFiles.html）无过滤器选择普通文件；adapt OWASP File Upload Cheat Sheet（https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html）的大小限制、摘要、随机文件名及不自动执行原则。当前为本机附件而非服务端公开上传，分离“接收原文件”与“解析已支持格式”；reject 为接收任意格式而自动尝试所有解码器或放宽解压上限。验收覆盖ZIP/图片/无后缀/损坏文档回退、本地持久化、同大小篡改拒绝、超限/链接拒绝、原文本提取及UI回归。

## 模型平台间歇性拒绝（2026-11-03）

每轮在员工私有 runtime 的 model-diagnostics/<run UUID>.jsonl 保存脱敏请求诊断：时间、run、请求摘要、协议、尝试次数、HTTP 状态、稳定错误分类、是否符合重试特征、白名单格式的平台请求编号。不得保存 URL、headers、Key、消息正文或工具参数。每轮最多64条，文件0600；诊断写入失败不影响聊天。此记录用于区分未命中重试、连续拒绝、工具续轮失败，不能把局部成功报告为上游已修复。

实测 BeeBridge 同一份 Chat Completions 请求首次 HTTP 400，原样再次发送 HTTP 200。仅对此服务商 `bad_response_status_code` 且正文精确为 `Request body format invalid` 或 `WorkBuddy AI: invalid function call parameters` 的 400 拒绝，等待 250ms 后原样重试一次。成功流开始、网络断开、其他 400、其他服务商和工具执行均不自动重试；终止信号禁止继续请求，重试仍失败保留原分类。不得删工具、改参数或重跑工具来掩盖错误。

行业做法参考 RFC 9110 §9.2.2（https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2）：非幂等请求不能普遍自动重试。此处 adapt 为已收到明确拒绝、尚未交付模型流的已实测兼容异常，严格限制服务商、错误特征和次数；reject 任意 POST/400 重试。验收覆盖一次恢复、持续失败最多两次、取消、普通参数错误与成功响应不重试，真实模型联调不得发送密钥到日志。

## 本地会话拖入文件（2026-11-03）

复用原 DesktopDrop 覆盖本地聊天区域（含输入框），松开后进入与选文件完全相同的本地导入流程：最多 5 项、普通文件、单项大小与总文本限制，异常保留原草稿，不自动发送或上传后端。拖入批次解析中拒绝并发添加；删除员工后的延迟结果不回填。组件移至共享包，旧桌面路径 export 保留单一实现。遵循 Flutter 插件回调适配到既有业务处理（https://pub.dev/packages/desktop_drop），adopt 原组件而非新拖拽 UI。回归拖入与点击选择均可生成原附件卡片及保持输入框 State。

## 工具配置仅来自模型服务

社区回归按实际流程覆盖：卡片 API 设置→兼容模型选择→保存对应服务商凭据→一键配置工具→CLI/桌面配置和验证；无知办设备授权不影响 BYOK。保留安装、恢复官方配置、代理/服务失败、升级与取消等行为断言。测试注入 Bridge 会话工厂，禁止启动真实 helper 或读取用户密钥；默认生产行为不变。

摘要样式：保留原弹框、选择按钮与弹层；地址/模型改为主题浅底信息区，固定标签列、值列左对齐并可换行，管理入口独立置于摘要下方。采用 Flutter Table 的固定列/弹性列布局（https://api.flutter.dev/flutter/widgets/Table-class.html），adapt 到只读摘要，不新增表单控件或编辑入口。深浅主题颜色取 ColorScheme/UiFieldStyle。验证使用现有选择保存回归，不为低影响样式编写镜像测试。

API 设置只允许从模型服务选择，移除地址/模型/Key 输入框和手动填写入口。复用原选择器，所选地址和模型仅摘要展示；Key 不回显。空目录或缺 Key 引导管理模型服务。旧工具配置只有匹配当前可用目录才回显。保存前重读目录，配置停用/删除或地址/模型变化要求重新选择，不能用旧地址配新 Key。采用单一配置来源和保存时校验（https://docs.flutter.dev/data-and-backend/state-mgmt/declarative），adapt 原组件，不增加平行表单。验收包含两工具、空目录、缺 Key、保存前配置变化与原管理入口。

## 本地工具复用模型选择器（2026-11-03）

Claude 列表修正：BeeBridge 目录显式声明附加 Anthropic 根路径，不能仅用默认 OpenAI 协议排除全部模型。Codex 保持 /v1，Claude 带入同源根地址；仅对与内置地址一致的配置使用此映射，自改地址不推测协议。原生 Anthropic 服务商保留。行业参考 Claude Code third-party integrations（https://code.claude.com/docs/en/third-party-integrations），adapt 显式多协议元数据而非移除全部过滤。验证依据：Bridge 原生产 Claude 地址 api.airick.cn，以及匿名 POST /v1/messages 返回 401（错误路径返回 404）；仅证明路由存在，不证明每个模型/Key 均可调用。验收包含 BeeBridge 列表、地址、密钥关联、刷新、改地址及不兼容服务商过滤。

API 设置复用聊天 ModelPickerEntry 与 AgentControlButton，支持原搜索、服务商筛选、模型图标、刷新和选中态。只展示兼容工具协议的已启用文本模型，排除自定义 header。选中带入地址和模型，保存时读取选定服务商 Key；只读展示地址和模型并保持目的端绑定。采用 Flutter 组合式组件复用（https://docs.flutter.dev/ui/widgets-intro），adapt 原弹层到设置对话框按钮位置，不新增替代选择器。验收覆盖组件类型、搜索选择带入、协议筛选及改地址不误用 Key。

## 本地明文凭据

用户明确选择不使用钥匙串，模型 Key 与本地开发工具 BYOK 均改用应用私有本地明文文件，重启保留。macOS/Linux 目录 0700、文件 0600，临时文件写入后原子替换，不记录密钥；不同服务商独立文件。绝不自动读取/删除旧钥匙串项，旧 Key 需在原设置重填一次。模型配置和 Bridge 地址绑定、删除行为保持。

行业实践与适配：参考 OWASP Secrets Management（https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html）采用最小文件权限、独立目录、原子保存；按用户明确偏好 adapt 为明文持久化，reject 系统钥匙串，拒绝以同目录固定加密密钥假装安全加密。持有当前用户权限的进程/备份可读取，安装说明明确标注。Windows 使用用户应用目录但本轮不声明已验证 NTFS ACL。验收覆盖无钥匙串调用、权限、重开、删除、损坏/链接拒绝和凭据目的端绑定。

## 回复保留阅读位置（2026-11-03）

用户修正：成功发送新问题时，将该轮用户消息定位到聊天可视区域顶部（首轮及后续轮均适用），仅执行一次；后续回复增长不跟随。发送校验失败不移动。沿用既有消息行 anchor 和回答最小视口高度，采用 Flutter ensureVisible 的 alignment=0 定位，不用滚动到底部近似代替顶对齐。

社区版本地会话收到回复增量、新增回答、工具状态或回复完成时，不自动滚到底部，保留当前阅读位置。首次进入会话仍定位最新消息；用户主动点击原“回到最新”按钮仍可到底。复用原消息列表，不新增组件。行业做法参考 Flutter ScrollController（https://api.flutter.dev/flutter/widgets/ScrollController-class.html）的显式位置控制；adapt 当前流式跟随机制，为本地会话关闭被动跟随，默认共享行为保留。验收覆盖短回复增长、新增回答、完成状态及手动回底。

## 输入框上下键恢复已发消息（2026-11-03）

桌面本地会话空输入框按 ↑ 恢复最近一条本人已发文本，继续 ↑ 浏览更早文本，↓ 返回较新文本直至进入历史前的草稿。历史只取当前员工本地已持久化用户文本，不取模型回复、附件正文或纯附件消息，不自动重发/恢复附件。到达边界不循环。手动编辑恢复内容退出导航；新发送、员工切换重置索引。普通非空草稿、附件/富文本块、IME composing、修饰键和已有候选浮层时保留原上下键行为。回复中仍可浏览和编辑下一条文本。

行业最佳实践与适配性：参考 [GNU Readline history](https://www.gnu.org/software/bash/manual/html_node/Commands-For-History.html) 的 previous-history/next-history 导航和 [Flutter Shortcuts](https://api.flutter.dev/flutter/widgets/Shortcuts-class.html) 键盘路由。adapt 到多行富输入框：仅空白开始导航，导航中才接管裸上下键，拒绝覆盖普通草稿或干扰输入法。复用原 PromptInput 和本地 SQLite 消息，无新服务、组件或账号依赖。验收覆盖顺序/边界/返回草稿、编辑退出、组合输入/修饰键/附件、会话隔离与原方向键回归。

## 回复详情刷新稳定性（2026-11-03）

同一员工的消息数据库刷新期间保留上一帧完整展示快照，不用旧 pending 行配合已清理的流式正文/时间线重画；最终行读取完成再替换。员工切换按员工 ID 隔离 FutureBuilder 与展示缓存，不能短暂显示前一员工内容。保留原 ChatSessionView、消息列表与输入框 State。采用 Flutter FutureBuilder 官方保留异步快照的做法，并适配当前数据库与流式内存两层数据，验收逐帧覆盖正文增量、工具状态、终态切换及员工隔离。

## 工具识别与失败恢复（2026-11-03）

社区版每轮给两种引擎提供宿主实际注册工具名、说明与参数 schema 的文字备份；禁止猜 tool_N 占位名，不按顺序映射未知工具，不提示调用未注册的能力。未截断的目录列表成功后停止探测，文件内容用 read_file，不将文件路径传给 list_files。文件错误按白名单分类反馈，不回显 stderr。

行业实践与适配性：adapt [MCP tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) 的真实工具目录及可恢复工具错误。当前上游间歇出现占位工具识别，采用真实目录文字备份和精确错误，不按编号猜测重定向调用，不扩大权限。验收覆盖真实服务商读文件、目录类型错误和两引擎审批回归。

## 模型工具协议与自选目录修复（2026-11-03）

工具 JSON Schema 的正则必须兼容服务商的正则解析器。工作表名称显式转义左右方括号，仍拒绝 Excel 禁用字符；不能通过删除工具或放宽宿主校验规避错误。社区直连失败按实际 HTTP 状态与有界错误字段映射为稳定错误码，界面不展示上游原文或凭据。工作目录按钮沿用原组件，显示已选目录名及完整路径提示，选择器异常进入原 Toast；回复中不可切换。

行业最佳实践与适配性：adapt [JSON Schema regular expressions](https://json-schema.org/understanding-json-schema/reference/regular_expressions) 推荐的通用语法子集，显式转义字符类内方括号，保留 Zod 宿主校验；adapt [OWASP Error Handling](https://cheatsheetseries.owasp.org/cheatsheets/Error_Handling_Cheat_Sheet.html) 的稳定错误和内部细节隔离，仅从受限上游错误字段分类，不回显原始消息。验收包含真实服务商完整工具请求、鉴权/限流/工具错误脱敏及自选目录的真实执行器读写。

## 免登录本地工具能力

用户明确要求：头像菜单本地开发工具与数字员工本地执行引擎均免登录使用自己的 API Key。方案与验收见 [ADR 0002](../adr/0002-community-local-tools.md)。创建员工继续保留原字段及布局，开放原引擎选择器；模型在会话选择。兼容引擎的模型走本地执行，保留文件隔离、审批、停止和原配置恢复。自动任务仍需登录。

## 行为契约

社区版桌面入口直接打开消息，不验证登录、不启动 Bus/WebSocket/运行时预热、不初始化账号相关产品后端。模型请求连接用户配置的模型服务（API Key 不等于离线推理）；技能广场匿名读取Bus公开目录及下载技能包，其他账号网络不初始化。

沿用现有模型服务配置；内置服务商保存 Key 后自动启用目录中的首个文本模型；目录没有模型时直连该服务商获取列表，选择首个文本模型。服务商不提供模型列表时提示用户手动添加，也可手动选择模型/地址。Key 使用应用私有明文文件；普通元数据仍用现有配置仓库，独立 community-local 分区，不读取历史登录账号配置。禁止将 Key 放进聊天数据库、错误信息或日志，不向重定向目标转发凭据。

用户可创建、编辑和删除数字员工（名字、角色提示词、技能；模型在对话时选择）。每名员工一个持续会话，消息页显示所有本地会话。对话按发送时的员工配置和技能组合系统提示，客户端直连模型，兼容协议使用本地工具引擎流式回复，其他协议使用文本请求，均支持停止请求；历史保存在应用支持目录 community_workspace_v1.db，不采用旧聊天缓存的 30 天清理规则。删除员工同时删除其会话/消息，需界面确认。失败和中断消息保留状态，失败回复不加入后续上下文。

技能广场只展示Bus当前响应；添加时下载并校验完整技能包，成功后绑定员工。已安装包及旧文本技能继续本地复用，不在全新安装中种入本地目录。

自动任务按用户最新要求：未登录不可使用。本地工作区仅显示未开放说明，不启动任务调度器、不执行或补跑任何任务。

本地 SQLite 不加密；持有设备文件访问权限的人可以读取对话。模型请求会将当前员工的历史和绑定技能发给用户选定的服务商。安装说明记录数据位置，聊天界面提示模型数据流向，自动任务页提示登录条件。

## 原界面保留要求（2026-11-02 用户修正）

数字员工只有一项时仍按原版桌面网格左上对齐，不水平居中。列表撑满可用宽度，卡片区外边距 12px、卡片间距 12px，列数按最小卡宽 292px 自适应，卡宽与原版使用相同计算，不因员工数量变少而改为固定两列。验收覆盖单员工在 900/1200px 窗口与多员工时的左对齐、列宽和无溢出。

### 密钥保存与自动启用补充

保存Key成功后立即启用服务商，保持现有展示顺序，启用首个可用文本模型。模型发现失败不把已保存Key误报为保存失败；服务商仍启用并提示手动配置模型。保存成功不代表Key已通过服务商鉴权。凭据保存遵循“本地明文凭据”一节。

免登录和本地存储只改变数据与执行方式，必须保留原桌面整体 UI：180px 可折叠渐变侧栏、原 SVG 导航及顺序、头像区与底部入口、240px 会话列表、原聊天空态/消息渲染/富输入框、数字员工卡片、技能卡片网格、页头及筛选搜索布局。复用现有组件，通过本地数据投影驱动；禁止再用简化 ListTile/普通文本框替代产品页面。

保留云盘、通讯录、自动任务等入口，未登录依赖账号的能力在原页面位置显示登录条件，不加载服务端 Provider。模型服务保留在原设置入口中，并在本地个人面板提供快捷访问。原有服务端模式的页面和会话 Provider 不得受到影响。

采用 Flutter [UI/data layer separation](https://docs.flutter.dev/app-architecture/guide) 的展示与数据职责分离做法：保留展示组件，通过本地仓库转换到已有展示模型；不为显示原 UI 伪造登录会话，不启动 SessionLayout。验收新增：侧栏折叠/导航、员工和技能卡片、聊天空态/发送/恢复和无后端网络检查，macOS 构建后重新启动供用户查看。

## 验收矩阵

### 数字员工创建/编辑与原版一致

模型选择修正：创建和编辑不选模型，也不要求先配置模型。对话输入框复用原模型按钮和选择器，保存每名员工上次选择。无选择或模型停用时要求选择，回复中禁止切换，下一条消息使用所选模型。不请求产品后端。

本地工作区必须复用 CreateAgentDialog/CreateAgentEditor，保留头像、数字员工名称、主要职责（必填）、人设、核心技能、应用、知识库、欢迎语、标签、运行位置、本地引擎、备注与原布局、校验、按钮。应用/知识库/云端保留入口但提示登录条件，不请求服务端；技能选择仅允许本地可执行技能，沿用原选择器组件。头像复制到应用支持目录，不上传。运行位置固定这台电脑，可选择DeepSeek Harness或Codex本地引擎，按模型协议使用真实工具，不兼容协议不冒充已执行。模型在对话时选择，创建/编辑保持原字段。

所有可编辑字段必须本地持久化并编辑回显；主要职责展示在员工卡片，人设留空时按名称和职责生成系统提示；欢迎语在新会话展示。SQLite 增加 metadata JSON 列，保留旧员工/消息/技能；旧员工职责以旧 prompt 回填，不丢人设。采用 Flutter 展示与数据分离惯例，给既有编辑器注入本地能力适配，不再建立平行简化表单。验收覆盖原组件与完整字段、必填校验、创建/编辑/重启回显及禁止后端请求。

| 场景 | 预期 |
|---|---|
| 全新无 token 启动 | 直接消息页，不请求产品后端 |
| 配置内置服务商 Key | 自动启用并提供默认聊天模型 |
| 创建员工并发消息 | 直连选定服务商，回复落盘 |
| 重开应用 | 员工、消息、技能恢复 |
| Key 缺失/HTTP 失败 | 显示安全错误；不编造回复 |
| 删除员工 | 确认后级联删除本地关联数据 |
| 技能绑定 | 系统提示包含所绑定本地技能 |
| 未登录访问自动任务 | 提示需要登录，不创建或运行任务 |

## 行业实践与适配

- Flutter 官方 [SQLite persistence](https://docs.flutter.dev/cookbook/persistence/sqlite) 建议结构化数据使用 SQLite；本项目已有 sqflite/桌面 FFI，采用，不新增数据库框架。
- SQLite [foreign keys](https://www.sqlite.org/foreignkeys.html) 默认须显式启用；采用 FK、级联删除和事务，保证员工/消息关联一致。
- 凭据按用户选择保存在私有明文文件，最小权限、原子写入、进程内缓存；不使用系统钥匙串，详见“本地明文凭据”。
- DeepSeek [Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion)、[Anthropic Messages](https://docs.anthropic.com/en/api/messages)、[Gemini generateContent](https://ai.google.dev/api/generate-content) 使用各自协议；适配现有目录元数据，使用独立 Dio，不复用带 Bus 身份拦截器的客户端。
- Flutter [生命周期](https://api.flutter.dev/flutter/widgets/WidgetsBindingObserver/didChangeAppLifecycleState.html) 不能保证进程终止后继续回调；当前不开放自动任务，不启动 Timer；后续如支持后台执行须使用独立进程及持久调度。

### 组件一致性补充

头像点击必须沿用原锚定向下个人弹框，不直接导航设置。本地分支沿用身份区、帮助与客服、检查更新、设置的原组件；不读取 auth/me、租户身份或触发退出登录。账号依赖操作提示登录条件。技能页使用原 UiSegmentedTabs、筛选栏、刷新按钮、排序下拉、搜索框、网格间距；「我的技能」沿用按技能聚合的员工列表和使用/移除操作。将原桌面纯展示组件提取到共享客户端包，由原页面和本地适配器共同复用，避免二次近似实现。验收覆盖头像打开/外点关闭/设置导航、技能 Tab 切换/排序/本地移除且不请求后端。

会话列表为空或搜索无匹配时，原图标与文案组成的空态必须在搜索栏下方的列表可用区域垂直居中；有内容时仍可滚动。

本地模式左下角不显示额外的设置文字或齿轮按钮（展开、折叠态一致）；设置统一从头像下拉菜单进入，底部保留官方社区入口。

## 全页面原设计核对（2026-11-02）

本轮不新增组件类。数字员工直接使用原 OpenClawDigitalEmployeeGallery（来源 Tab、添加更多、卡片详情、编辑、删除），仅注入本地目录和操作回调；搜索和新建按钮保持原桌面布局。技能详情与安装目标分别使用原 SkillDetailDialog、SkillInstallAgentDialog，保留添加后使用的交互。删除确认使用原 showUiConfirmDialog。聊天模型选择沿用原按钮与 ModelPickerEntry 的尺寸、图标和菜单样式。账号受限页面使用对应模块现有反馈组件，不借用聊天空态。

行业实践采用 Flutter 展示与数据分离（见前述官方来源）；当前已有原组件，采用可选本地数据与回调适配，拒绝平行简化界面及伪造登录状态。验收覆盖原组件类型、筛选、卡片详情进入聊天、安装后使用、本地持久化和零产品后端请求；服务端入口默认行为保持不变。

## 本地附件读取与分析

复用原富输入框附件按钮、附件卡片、消息文件展示和 AttachmentPreviewHost 右侧预览。用户主动选择文件后，本机解析并暂存；点击发送才将提取文本与该员工历史发送到所选模型服务商，不调用产品后端。支持仅附件发送、删除待发附件、切换员工隔离草稿、重启后查看已发送附件。解析失败保留原文件，未选模型时保留输入。

支持 UTF-8 TXT/Markdown/CSV/JSON/代码文本、DOCX 正文、XLSX 单元格和 macOS PDF 文字层（系统 PDFKit）。其他格式均允许添加原文件；未提取文字时由本地工具处理，不声称已具备OCR或任意格式解析能力。其他桌面系统的 PDF 解析暂不开放。每次最多 5 个文件、每个 10 MiB、每个提取文本最多 60,000 字符、一次总计 120,000 字符；原文件超限拒绝，提取超限保留原文件，不静默截断。DOCX/XLSX解析限制条目数和总展开大小，不运行宏、脚本或外部链接。解析在独立 isolate（PDF 在系统后台队列），不阻塞界面。

已发附件复制在应用支持目录 community_attachments/<员工 UUID>/，数据库 messages.attachments JSON 保存名称、托管路径、大小和文本快照，升级保留历史。删除员工清理其托管目录；待发附件只存在内存，不上传、不留副本。模型接收文件名、提取文字和工具工作目录相对路径，不发送附件私有绝对路径。SQLite 与原文件均未加密。

### 行业最佳实践与适配性

参考 [OWASP File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)：采用已支持格式解析、大小限制、随机托管文件名、解压后限制，拒绝目录遍历和执行；当前为用户主动导入的单机文件，无服务端上传。参考 Apple [PDFDocument.string](https://developer.apple.com/documentation/pdfkit/pdfdocument/string)：适配系统 PDFKit 提取文字，不引入商业授权 PDF 组件或联网转码；无文字层保留原件供工具处理。DOCX/XLSX 按 OOXML XML 部件读取，不执行内容；文件作为用户数据进入消息，不提升为系统指令。原预览 Host 提取到共享包，桌面旧入口 export 同一实现，不新增 UI。

验收：真实文本/DOCX/XLSX 提取、空/损坏/提取超限保留原件及原文件超限拒绝、SQLite 升级与重开、附件上下文与路径不出站、原附件卡片/右侧预览、零产品后端调用、macOS 构建重启。真实服务商和扫描件 OCR 不以 mock 测试冒充完成。

## 凭据读取缓存

同一进程内按完整scope/provider key复用已成功读取或保存的密钥，并发读取合并。保存成功更新缓存，删除和写入失败使旧缓存失效；过期异步读取不能覆盖新值，读取异常允许重试。底层使用本地私有明文文件，不访问钥匙串。缓存只存在内存，启动不预读全部服务商密钥。验收覆盖重复/并发读取、保存/删除/失败重试与异步旧值覆盖。

## 聊天处理中状态与附件输入稳定性修复

composerEnabled 只表示员工是否可继续会话，不能绑定请求 busy 或附件解析状态。本地员工仍存在时保持原输入框挂载；回复中由 isSending 显示原停止按钮，解析期间通过 sendReady 暂停发送但保留草稿和焦点。消息 Future 按工作区数据修订缓存，附件/焦点等局部变化不得重查消息或重建输入框。pending 消息投影 streamStartedAt 为持久化创建时间，使原等待状态在重建后不会重新计时。继续沿用既有思考/处理状态，无新组件。

采用 Flutter [FutureBuilder](https://api.flutter.dev/flutter/widgets/FutureBuilder-class.html) 官方要求：Future 应在 build 前获得，不能每次 build 重启异步任务；适配本地仓库修订后刷新。验收覆盖选择文件解析前后同一个 PromptInput State、原草稿保留、回复中停止按钮可用且无员工删除提示，完成/停止后恢复发送。

## macOS 本地连接组件签名修复

社区非 Release 构建使用 ad-hoc helper，不能要求商业 Developer ID Team。该分支仍执行 codesign strict 完整性校验、固定 helper bundle 路径和 identifier 校验；Release 保留 Apple Developer ID + Team 要求。不得自动打开跳过签名开关，不读取或修改用户凭据。验收同时检查完整性命令成功、实际组件 initialize/settings RPC 以及客户端重建。

适配判断：adapt Apple Code Signing Guide（https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Introduction/Introduction.html），区分开发身份与发行信任，不将开发自签名误认为已具备发行证书。

## 公开技能包本地安装（2026-11-03）

### Review 修复契约

API 设置改变完整规范地址后必须重新提供 Key；界面和 Bridge 双层拒绝复用旧地址凭据。发送前校验当前消息（含附件包装）最多 150000 字符、人设及技能合计最多 200000；历史保留最新完整消息至 JSON 500000 字符，上限与 helper 一致，超限不清草稿、不落用户消息。附件文本总量仍为 120000。运行时仅可从当前员工 community_attachments 私有目录按摘要导入普通文件，复制到工作目录唯一的新子目录，不覆盖用户源文件；模型获得相对路径并沿用原工具权限。损坏技能在原安装弹框显示“重新安装”，校验恢复成功再显示“使用”。删除员工前清理其 community-runtime 与 community_attachments 私有目录，保留用户工作目录和共享技能包。

行业最佳实践与适配性：adopt OWASP Secrets Management 的凭据目的端绑定（https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html）；adapt OWASP File Upload 的隔离、摘要与大小限制（https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html），结合现有 host/broker 将附件授权限定到当前员工快照；adapt Flutter offline-first 的本地状态与恢复分离（https://docs.flutter.dev/app-architecture/design-patterns/offline-first）。不采用扩大 sandbox、自动运行附件或删除用户授权工作目录。验收覆盖已有密钥改地址、超限草稿、长历史裁剪、真实附件导入及拒绝越界、损坏包恢复与删除隔离。

沿用原详情“添加”与员工选择弹框：选择员工后匿名下载单技能 bundle，验证响应 SHA-256、manifest code/版本/内层包 SHA-256，安全展开完整 SKILL.md/scripts/references/assets 后原子存入应用支持目录。SQLite 单独记录安装版本/文件摘要/路径和技能指令；成功后才绑定，失败不改变员工。并发同技能下载合并，重启离线复用已验证安装；目录刷新不覆盖已安装版本。

聊天加载真实 SKILL.md，工具运行时接入既有 skillsDir 只读挂载；文本模式仅加载技能指令。每轮按文件摘要重新验证并在员工私有 runtime 下生成完整技能快照，拒绝篡改/缺失/链接。脚本安装时不执行，运行时仍遵守原本地工具审批。保留原本地文本技能和员工绑定。

系统上下文明确列出关联技能 code，以及 read_skill_file/copy_skill_file 的资源使用方法；不能只依赖原生 skill 名称发现，市场 code 与原生 frontmatter name 可能不同。损坏包在再次“添加”时重新下载，替换成功前保留原安装记录；聊天仍拒绝损坏内容。

行业最佳实践与适配性：adopt Agent Skills specification（https://agentskills.io/specification）的指令及资源目录结构；adapt OWASP File Upload Cheat Sheet（https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html）的白名单路径、字节/条目上限、摘要及隔离。bundle 最大 200 MiB、内层包 50 MiB、展开总量 100 MiB、2000 条目、SKILL.md 200000 字符；拒绝绝对/穿越/重复/链接/特殊类型。只用独立匿名客户端、固定公开接口，不记录签名 URL 或凭据。

验收：真实线上包下载安装/重启/聊天指令与完整资源只读可见；失败/篡改/穿越/损坏不绑定；沿用原 UI；Flutter 定向测试/analyze、runtime typecheck、macOS 构建。
