# 可选服务器工作区踩坑

## 客户端验证须核对源码与运行版本（2026-11-12）

旧 desktop Bus 保留过往接线，而当前源码漏注册附件、群聊、职位与会话技能入口。只测旧部署会掩盖重新编译后的 404。应临时运行当前产物、核对 `/proc/1/exe` 摘要，再使用真实 Flutter 服务和 IM SDK 验证；成功产物需明确是否已经持久部署。

人机直聊的 `conversations.digital_employee_id` 可能为空，员工在 `room_participants` 中。技能栏仅按旧字段找员工会返回 404。先校验当前账号可访问会话，再核对 room 同租户及 `direct_room_kind=human-agent`，从唯一未退出的员工成员解析；不可凭 room ID 或第一个成员绕过访问控制。

现有 E2E fixture 的其他租户 token 会过期。跨租户验证应使用真实登录后的 scope 切换获取新 token，避免将 401 误记成跨租户拒绝；仅有一个租户的环境应明确跳过，由其他已有环境补验。

- 2026-11-12 范围纠正：内网已有能力不应在社区重复新增后台、接口或数据库脚本。先复用内网对应文件；用户明确不补功能时，导出遗漏只记录限制，不能继续补表、合并迁移或设计兼容分支。本轮新增 000014–000022 已从源码撤销，现有数据库及账本保留。下列扩展功能排查为历史经验，不代表当前源码已交付。
- 临时 Compose 联调被终止后可能留下整套数据库和对象卷；显式 --keep 只用于必要诊断。捕获 SIGTERM/SIGINT 进入 finally，检查 down -v 结果；清理失败返回失败并给出本项目清理命令。不能把成功路径日志当成所有历史测试环境都已清理。

- KB 检索的 ChunkDTO.UUID 在 PostgreSQL 路径是切片 UUID，RAGFlow 路径可能是提供方文档 ID；不能直接作为 external retrieve 的 document_id。应用检索须按当前 KB 下的 document_id 批量映射 kb_documents.uuid，缺映射时拒绝输出；用检索返回的 ID 再读取文档详情验收。应用借用不能复用会持久化 query_text 的用户 Search 路径；独立只读入口保留权限/提供方校验，审计只记录能力与路由模板。

- OAuth code/refresh 未过期不代表授权仍有效。签发必须重查应用、client、scope、租户开关、账号、成员与强制改密状态。共享 room 的 conversations.account_id 是创建者，不能替代当前成员访问校验；同时区分 dm、agent_chat 和 group。secret/code URL/token 响应禁止缓存。
- 工作台列表有应用不代表可以启动。OAuth 应用须调用 Bus launch 获取一次性 code，不能直接打开 launch_uri 或拼 dashboard token。空 conversation_uuid 须单独验证通用开关，不能绕过应用可见性。

- 复用来源分类时不能只注入公共 platform、把 enterprise/personal 固定置空，再显示“组织/我的”。显示层合并公共与服务器目录，按来源保留不同操作；验收必须逐个点击分类，不能仅看全部网格。公共失败不得遮挡服务器员工。

- 员工列表、详情与保存响应须共用真实能力投影。只返回应用标签却漏掉 apps[] 会让编辑框能看见、聊天能力栏却为空；漏 local_engine 会把 Codex 编辑回显成 DSH。客户端须区分“没有返回绑定字段”和“已返回空绑定”，空数组不能再回退旧 metadata 标签，否则解除绑定后再次编辑会重新装配。联系人 DTO 往返也需保留部门。联系人能力 Resolver 需要在社区 Bus 入口实际装配；只测会合并 /agents 的客户端个人目录，会掩盖原始 /contacts/agents 缺能力的问题。用绑定/解除/改名/再次编辑验收，不能只测创建后的 HTTP 200。

- 桌面对话路由就绪早于 ChatNotifier 异步恢复默认会话；只在路由 false→true 时标读会漏报，界面已展示消息但数据库 last_read_at 仍旧。历史成功恢复后重新检查路由、当前选择与生命周期，再走统一标读；刷新补报也不能把其他页面或后台会话清零。列表请求若在标读期间发出、在确认后返回，仍属旧快照，必须保留请求开始时的标读保护集合。免打扰只影响通知，不能跳过当前会话的水位写入。

- generic 运行时曾直接查询 messages.History，只在 UI 历史接口应用 cleared_at，导致清空前内容仍进入模型请求。运行时也必须传触发账号的水位；查询水位失败时禁止调用模型，不能回退全量历史。发布快照已有 system_prompt，排查人设时先核对 BuildSnapshot，不能只看草稿 metadata 就断定漏读。
- 原生登录窗口会从主窗口位置移动并缩小，截图前重新读窗口 bounds；整串 CGEvent Unicode 注入可能截断长文本。输入脚本失败不等于产品登录失败，必须核对服务端鉴权记录。

- 复用群服务必须核对完整装配：WuKong 群 @ 强制 ForceQueue，缺少 chat_message_tasks 仓储和 Bus worker 时 webhook 仍可能 200，但不会产生回复。验收必须同时看到当前消息的 final IM、队列 done 和 outbox sent；不能删 ForceQueue 绕过串行与持久化。
- 旧群服务先 UpgradeDirectToGroup 再检查 caller membership，会使越权请求改变房间；而原 direct channel 与新 group channel 的命名也不同。社区先只暴露已有 group 的成员管理，授权在任何写入/订阅之前完成；单聊升级另行完整实现。
- 群详情曾直接返回 accounts.email，绕过通讯录 field_mask。成员身份与联系方式权限分开处理；邮箱按当前 caller 的 contacts.GetMember 字段裁剪结果返回。展示名/部门/组织查询下沉仓储，不能在 service 放 SQL。
- 最终员工消息的 ImMessage.text 是会话摘要，长内容会截断；真实回复关联应检查 stream_id / agent_message_status 及完整 blocks，不能用被截断的摘要匹配长标记。

- 浏览器 StrictMode 的首轮 effect 会立即 abort；GET 去重若复用带调用方 signal 的 Promise，第二轮会收到已取消请求并显示错误。带 AbortSignal 的请求必须独立执行，不参与跨调用方去重。

- 标准技能包即使不含标签，也会读取标签字典；包上传后运行时依赖 skill_version_files。社区 baseline 原先缺少这三张表。空列表和 mock repository 单测不能证明导入可用；必须在全新库验证导入、重复导入、装配回读和实际运行，文件投影失败时保留 draft 并报告失败，不能吞掉错误后发布。

- `communityEdition` 是发行能力开关，不能当作“当前离线/已连接”。直接改成 false 会同时改变模型 Key 范围、商业接口、更新和设备授权行为。连接地址单独配置。
- Dio、TokenRefresher、RequestInterceptor 的 token 缓存、IM 与 LocalAgent 都有进程级状态。只换 baseUrl 或 ProviderScope 不能保证隔离。切换需卸载旧 UI，封锁旧连接，等待已开始的凭据写入/登出结束，再清理会话、关闭旧 Dio 与更换地址。刷新持久化之后、填回内存缓存之前仍需检查连接代数。
- Riverpod 上层测试覆盖会把 Provider 的归属提升到上层容器，无法据此验证内部工作区 ProviderScope 的真实卸载。切换回归使用真实临时 SQLite、真实内部容器，验证新控制器和持久化数据。
- 桌面 widget 测试必须模拟 screen_retriever 的 double 尺寸/位置、window_manager 的 getBounds 和 RTC EventChannel；否则原生插件缺失会被误判为切换失败。图像编码/字体加载须在 tester.runAsync 内等待。
- 员工聊天测试的服务替身也须覆盖会话缓存、历史缓存及同步入口；仅覆盖 getHistory 会继续走真实 SharedPreferences/SQLite。在 widget 的 fake async 内等待原生缓存调用可能一直挂起。用空缓存和委托到既有 getHistory 的同步替身隔离插件，保留聊天选择、历史调用和未读断言；IM 同样注入现有替身。
- 流式聊天的非 RTC 测试应注入内存 RTC 控制器；局部 EventChannel 桩只覆盖 widget 用例时，前一个普通用例的异步取消可能跨到下一个用例，产生缺插件异常。错误回归按核心包既有契约精确断言安全文案和稳定错误码，不删除失败状态、HTTP 状态或历史恢复断言。
- 当前 main 的扩展回归有两项旧文案断言失败：模型错误现含稳定错误码，任务页不含旧“关闭后暂停”提示。本次未改这些行为，不通过修改无关业务或弱化测试掩盖。
- 独立 SYMROOT 的 macOS 增量构建可能留下外层 app 对 App.framework 的旧 seal。先分别严格验证 framework 与 app，再用原 entitlements 重签预览包外层并重新严格校验；不以 --deep 或放宽校验掩盖 nested code 错误。该修复仅用于临时 Debug 产物，不能据此声称 Release 签名/公证通过。
- 社区 baseline 不一定包含共享服务的辅助表：技能 rail 会读用户装配/租户停用表；知识库上传会写容量与文本分片表。只测空列表无法覆盖这些依赖。记录导出依赖缺漏；当前范围不追加迁移或新建测试库，不忽略数据库错误以绕过权限策略。
- Bus/SSE 成功不代表最终 IM 投递成功；community-worker 消费 WuKong outbox。真实 SDK 验收须按本次 stream_id 匹配 final 消息，避免旧消息使测试误通过。
- PostgreSQL NULLIF($n,'') 会将参数表达式解析为 text，写 UUID 列须显式 ::uuid。知识库召回日志原先忽略写入错误，检索 200 仍可能没有日志；集成验收还要检查日志落库。
- Flutter test 默认替换 HttpClient，真实网络验收须显式撤销该测试替身，并隔离 SharedPreferences、SQLite、路径插件和 IM 缓存。connectivity/path 插件可以模拟，业务 HTTP、WebSocket、数据库和对象存储仍必须真实。
- 公开树的 internal/service/skill/rail_failure_test.go 引用了未随仓库提供的 zapRailRepo / newZapCarrierFixture，扩大 Go 测试会编译失败；这是独立的测试夹具缺失，不能据此移除 fail-closed 断言。
- 服务器页面只读 `/contacts/agents`、`/skills`，不自动继承本地工作区的匿名公共目录。接入服务器后列表空不等于公共接口停服；分别检查公共目录、租户员工和服务器技能。公共模板 UUID 不能直接当服务器员工 UUID 使用。
- 装配服务存在不代表客户端可操作：`can_manage_skills=false` 会让目标选择器始终为空；详情不 hydrate `skills[]` 又会让已装技能在编辑保存时被清空。能力标记、真实绑定、回读与租户/创建者校验必须一起验证。
- 本机持久部署与临时联调要用不同项目和卷；不能直接使用联调脚本的自动 down -v 流程。缓存镜像也不能代表当前源码，须重新构建或覆盖编译程序与管理台产物。遇到 Node 官方下载超时可换镜像源，但必须核对官方 SHA256；不要只因下载成功就执行。

- WuKong v1.2.6 的 device_quit 只踢当前连接，不清除 user/token。真实 SDK 测试可用旧 token 重连。成员停用/移除须先给 App/Web/Desktop 三种 device_flag 写入独立随机替代 token，再退出全部设备；不得把“看见断线”当作撤销验收。替代 token 不返回给客户端、不落日志。
- 新成员的强制改密标记同时出现在 account.mustChangePassword 与 JWT mc。只有 Admin 挂 RequirePasswordValid 会留下 Bus/IM 绕过路径；所有业务路由须统一挂载，身份/改密/退出白名单不能依赖已选租户。

- WuKong v1.2.6 options.go 虽注释 release 默认鉴权，但实际 TokenAuthOn 初始值 false，读取 mode 不会自动改 true。仅设置 WK_MODE=release 不能证明鉴权生效。Compose 和独立验收显式设置 WK_TOKENAUTHON=true；必须用旧/错误 token 的真实重连失败验证。来源：WuKongIM v1.2.6 internal/server/options.go 与 cmd/root.go。

- 2026-11-12 实测：恢复内网仓库中的 community 入口只代表恢复社区旧基线，不等于接入内网完整 Bus/Admin 装配。编译通过后仍可能出现聊天附件/群路由缺失、技能管理标志关闭、模型目录 404 和 positions 被动态员工详情路由捕获。必须用当前编译程序验证；旧部署未更新及已有辅助表会掩盖源码/空库问题。收缩数据库变更时不能把“删除扩展代码”当作“功能保持可用”的证据。

## 完整后台入口与菜单缺漏（2026-11-12）

复用后台必须从日常 src/main.tsx 的全部相对依赖与 public 登录图片开始，不能把 src/community 简化台当作原后台。只切入口不复制 login-assets 会导致 SPA 返回 HTML 冒充图片；静态部署需包含图片并回退 index.html。

真实登录的 me/menus 返回 null，源于社区没有原菜单数据；原 Layout 对 null filter 会白屏。原版与公开版同步将 null 当空数组，不能用硬编码菜单、权限绕过、数据库补丁或假统计掩盖缺漏。后台登录成功不等于完整后台可用；必须核对菜单、统计和角色等真实 API。
# 2026-11-12 完整后台续修：装配、权限与构建

后续导航修正：schema-only 导出没有菜单数据，社区 RBAC 后续脚本也没初始化 menus；页面存在时，不能把“菜单表为空”当成必须补库才能显示导航。用户已明确授权社区版从现有页面直接提供全部导航：复用 pageMenus 与 Layout，后端授权照常，部分业务不可用仍如实报错。此前禁止静态菜单的范围已被此次明确要求替代。

- 容器 Up 只证明主进程存在。现有 Admin 没有 `/healthz` 或 `/auth/me`，用 `/api/admin/v1/me` 匿名 401、真实登录/me 200 和 `/proc/1/exe` 摘要确认恢复；不能把错误探针的 404 当作宕机。
- admincore 引用 platform/position 但服务包未导出，Go 可能先因远程模块解析超时报错。补齐原服务源码闭包后用 `GOPROXY=off` 验证；不要把本地缺包误判为需要升级依赖。
- 现有测试库只有 23 个权限点、无菜单种子。路由从 404 变为 403 只代表装配和拒绝策略正常；直接只读调用服务仍可能因 emp_block_registry/kb_ingest_jobs 缺表失败。不得硬编码菜单、删除权限检查、伪造统计或自动补 SQL。
- 原 RBAC 服务按全局 role ID 读取/修改；新增 tenant HTTP adapter 必须先校验角色 scope 与 tenant，不能只检查 URL 权限。跨租户 read/update/delete 必须回归。
- ChatGPT 内置 Node 可运行 ESLint/TypeScript，但加载 rolldown 原生模块时报 `different Team IDs`。根因为宿主签名的 library validation，并非缺依赖。仅对复制到临时目录的 Node 做 ad-hoc 签名后构建；不重装依赖、不更改应用内 Node 或项目原生模块。


## 页面全 404、运行程序与回滚（2026-11-12）

症状：全部导航显示后，原页面大量 404。原因：38082 静态台指向 38081 desktop Admin，源码和临时 E2E 的路由更新不等于当前服务更新。逐页采集 API，核对 nginx、容器 command、readlink /proc/1/exe 和实际摘要；完整情况见[验收](../verification/admincore-2026-11-12.md)。

- 原路由可能由子 handler.Register 注册；机械提取 mux.Handle 会漏掉告警。路由测试必须同时注册所有模块，验证实际路径与原权限码。
- /tenant/a2a/approvals 缺 literal 路由时会被 /tenant/a2a/{edge_id} 捕获返回 400，不能只找 404。原服务 a2a.New 在构造时检查 Edges、Agents、CapabilityRepo、SessionDeriver，编译测试不代替真实启动。只开放审批读取，不能接默认 NoopInvoker 的决策路由。
- 容器用户 10001 无权替换 /usr/local/bin；原子替换需 docker exec -u 0。若新进程在 restart loop，exec 回滚也会失败，应 stop 后 docker cp 原程序到正确路径、start，再核对 401 存活和真实登录。运行二进制禁止原地覆盖，停止后除外。
- E2E 使用 /e2e-bin/community-admin，镜像 /usr/local/bin 不是实际进程；只比较后者会错误报告恢复失败。desktop 临时替换则在重建时丢失，应生成独立本地 Admin 镜像并让该服务引用，实际重建验收；不重建 Bus 或数据服务。
- Docker 容器记录的 image config ID 不一定仍能作为本地镜像引用，BuildKit 会把不存在的 FROM sha256:... 当成仓库名去远端解析。先检查本地可用标签，禁止把这类等待误认编译卡住。
- 403 代表原权限拒绝，500 需核对实际查询与缺表；不能通过空响应、权限通配或 SQL 补丁计为修复。导航与请求成功分别验收。

- 本地工具目录新接线使用上游 howett.net/plist v1.0.1，公开模块遗漏时 go 可能先尝试读取无关 difflib.mod 并超时。先检查新增 import 与上游依赖，补同版本 require/checksum 和导出 overlay；用 GOPROXY=off 验证已有缓存，不改业务逻辑规避解析库。


## 本机 Docker 软件源 HTTP 不通（2026-11-12）

当前主机 curl HTTPS Debian Release 成功，HTTP 超时，Docker apt 对 deb.debian.org:80 的请求无法连接到解析出的 198.18 地址，导致文档解析依赖安装失败。构建使用官方 Go 基础层中的 CA bundle，引导 Debian slim 通过 HTTPS 源安装标准证书包及原解析依赖；保持 TLS 校验，不删 Office/PDF/OCR，不用 --allow-unauthenticated 或 Verify-Peer=false。首次新部署须实测构建，不能用另一台电脑的镜像结果替代。

本机后续构建证据：HTTPS 软件源可访问后，Go 模块 zip 和 Corepack/Node 下载仍在 Docker bridge 直连时遇到 unexpected EOF/UND_ERR_SOCKET；使用 Docker Desktop 已有 http.docker.internal:3128 代理的独立 BuildKit curl 探针返回 200。仅本机 build 命令传标准 HTTP(S)_PROXY build args，Node 构建下载显式 NODE_USE_ENV_PROXY=1；不将代理写入运行容器配置、不关闭 TLS 或 Go 校验和。

### UI 新建任务仍可能失败，不能仅测 POST /cron/jobs

2026-11-13 实测 UI 创建任务先读取 /cron/prompt-templates；即使直接创建和执行成功，漏接模板路由仍会弹 404。应从原弹窗依赖开始验收，接回原处理器及其原表约束，不将模板读取失败吞成空列表。社区免责声明开关也必须覆盖服务器聊天宿主，不能只在免登录本地入口关闭。

### 本机 UI 验证后保留活动会话

Flutter integration_test 完成会卸载 Widget 树并退出测试应用；不能将之后重开即回本地的窗口当作“保持服务器登录”。此次用 opt-in LiveWidgetController 驱动真实 CommunityWorkspaceApp，所有步骤完成后保留 Widget 树和会话，再恢复磁盘上的正常 main 构建入口。默认 FlutterDriver 帧同步会等待常驻动画而阻塞，不能把驱动等待当业务失败或放宽 UI 断言。

### 多来源目录已有数据不等于全部加载完成（2026-11-13）

公共目录与服务器组织目录是独立异步请求。只用合并后列表是否为空来判断 loading，会在组织先返回时隐藏公共目录的等待状态。加载态应按来源保留：已有卡片继续显示，当前分类所需的未完成来源追加同款骨架；完成和错误都移除占位。回归必须覆盖“组织先成功、公共仍等待”、分类切换、公共成功/失败，不能只测全空首屏。

### 人际单聊 UI 装配与本机宿主休眠（2026-11-13）

只有 direct-room 创建/SDK 发送通过还不够：通讯录进入还调用 conversation show，发后需要本人消息回执和已读临时信号。缺失路由会在能发消息时仍弹 404；复用原 StateHandlers、messagereceipts 及 sender/成员校验，不吞错为空。真实两客户端 UI 与访问拒绝均需验证。

本机 Docker 后端随 Mac 合盖休眠暂停；任务只能在宿主获得 CPU 时调度。此次运行/pmset 时间对齐证明多次维护唤醒及一次流失败重合，未保留底层异常时不能精确归因为网关或休眠。临时验证账户额外 HTTP 登录也可能替换 UI 会话，不要将其制造的回登录页误报为 UI 产品故障。

### 切租户不能删除未轮换的续期凭据（2026-11-13）

原 SwitchScope 只重签 access，保留服务端同一 sid 的 refresh hash，因此响应没有 refreshToken。通用登录保存函数把缺字段误当注销，导致每次登录后自动选租户也丢续期能力：15 分钟后 401，TokenRefresher 因本地 refresh 为空判 invalid，未发续期请求便退登录。修复：仅 scope switch 显式保留当前 refresh，并核对前后 aid/sid；普通登录不携带 refresh 仍清旧值。不能全局采用“缺字段就保留”，否则会跨账号/会话沿用凭据。

真实 Flutter test 默认拦截所有 HTTP，实联用独立 HttpOverrides 的基类真实客户端，不能把测试绑定返回的 400 当服务端问题。正式 UI 验证使用独立账号和独立 bundle，通过一次请求头失效注入触发原后端真实 401，不伪造服务端成功。不得在同一管理员账号上重复登录来测试续期。

### 静态官方资源迁移（2026-11-13）

只替换目录主机不够：旧技能下载为 POST 动态 export，须改为静态 GET + 清单 SHA-256，静态包仅允许配置站点 packages/ 路径（包括重定向）；相对地址必须基于含仓库路径的完整根 URL 解析，不能丢掉 /skills/ 或 /agents/ 或拼出端口后缺斜杠的非法 URL。旧员工/会话存储的图片须在统一图像组件按摘要改址，且不能带原 Bus token。

首次导入发现 arxiv-translator 的 5 个文件使用 Windows 反斜杠路径，原安全安装器会拒绝。导出到资源源码时规范化为安全正斜杠并重新生成确定性包，禁止放松客户端解压校验。第三方 Markdown 保留原始换行/空白，未为压平 diff-check 改写资源内容。Pages 构建先核对包和目录，再将其作为同一 artifact 部署；首个资源 Git 提交未推送时，Pages 仅启用配置，不能算资源已上线。


### 图片 UI 验收不能把占位图算加载成功

AgentAvatar 的 placeholder/error 都使用默认机器人图片，自身也有已解码的 RawImage。只检查 RawImage 会在网络头像尚未完成时提前截图并误报成功。原生 UI 验收必须检查 CachedNetworkImageProvider 的 Image 及其已解码 RawImage，且 RawImage 最近的 Image 祖先必须是该网络 Image。因为 Image.frameBuilder 会把 AssetImage 占位嵌套在网络 Image 下面，仅检查网络 Image 的任意后代仍会误判。默认 AssetImage 不算通过。失败保留原始异常，不让失败截图再次抛错覆盖结果。

图片解码完成与屏幕完成绘制不是同一时刻。LiveWidgetController 验收在检查真实图像后必须再 pump 下一绘制帧，并等待 endOfFrame 再做 RepaintBoundary 截图；单看网络成功、RawImage 或控件树不能替代截图复核。

LiveWidgetController.pump 会等待真实 endOfFrame。独立原生窗口不绘制时会连同超时循环一起停住，不能直接判定 HTTP 超时；先检查该独立窗口的可见性并置前，不能为唤醒测试而操作用户会话。
