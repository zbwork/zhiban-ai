# 本机社区版两个里程碑验收

## 最新结论：里程碑一重新通过（2026-11-13 下午）

当前源码 + 本机真实后端，独立 account 2 / 3、独立 macOS bundle，经实际 UI 重新连接、通讯录、双向聊天、创建服务器任务并退出创建端后继续执行均通过。新增本地通知由用户实际看到并点击，原生 nativeClicked 回调与跳转后的聊天截图均已核对。以下历史章节保留当时失败及修复过程，不取代本节当前结论。

| 范围 | 本轮结果 |
| --- | --- |
| 点击连接服务器、密码登录及租户 | 两个独立成员实际 UI 通过 |
| 拉取通讯录成员并打开单聊 | 双方 UI 通过 |
| 服务器定时任务 | UI 创建，创建端退出期间到期执行，重连 UI 看到真实回复；9 次运行全部成功 |
| 两人双向聊天及历史 | UI 双向收发，重启后历史保留 |
| 人际消息本地通知 | 系统送达 + 用户看到并点击 + 原生点击回调 + 正确会话 UI，通过 |

仅对应本机 macOS / 回环服务，不代表第二里程碑、Windows、远程部署或长期休眠稳定性全部验收。通知的共享屏幕开关曾获授权临时改为允许，恢复时 CUA 连续超时；用户随后要求停止处理通知，未确认恢复，不能记录为已恢复。

用户 2026-11-13 明确：所有验收必须通过实际 UI。API、SDK、单测只作为辅助证据。后端及客户端均在本机；不使用构建机、不推送 Git。

## 里程碑一

| UI 流程 | 状态 | 辅助证据 / 阻断 |
| --- | --- | --- |
| 客户端点击连接服务器并登录本机 | 真实 UI 通过 | 管理员、验证成员均经 UI 连接 18080 并登录 |
| 通讯录实际展示成员 | 真实 UI 通过 | 双方默认部门可见对方，从详情点击发消息 |
| UI 创建/执行服务器定时任务 | 核心流程 UI 通过 | UI 新建，创建端退出后服务器到期执行，重连查看结果；留跑休眠异常见下文 |
| 两个账号从 UI 互发消息 | 真实 UI 通过 | 两个独立 macOS 客户端在线双向收发；重新打开会话保留历史 |

## 里程碑二

| UI 流程 | 状态 | 辅助证据 / 阻断 |
| --- | --- | --- |
| 管理台登录 | 通过 | Chrome 实际表单进入 /dashboard |
| 概览 | 失败，待修复 | 页面显示 requires platform.overview.read，原导出权限种子缺漏 |
| 租户创建/管理 | 待 UI 验收 | API 创建本机验证租户成功 |
| 员工选择 DSH / Codex App 并保存 | 待完成 | 需核对已有配置契约与实际执行，不把保存当执行成功 |
| 开源版其他已提供配置 | 待清单核对并逐页验收 | 不以显示导航代表能力已接线 |

## 环境及实际修复

- 当前独立项目 `zhiban-community-local-20261113`；Bus 18080、Admin 18081、管理台 18082、WuKong WS 18083、对象存储 19000，仅回环暴露。
- 默认项目名曾匹配 10 月旧数据卷，认证失败，未运行迁移/修改旧数据；已停止本次启动的默认项目容器并保留旧卷，换用上述独立项目。
- 原 13 迁移成功；追加 14 知识库、15 技能辅助结构及 16 原技能 RBAC 种子，复用上游正式 SQL，旧迁移校验和不变。
- 真实 Flutter 服务 + WuKong SDK 实测：登录/租户、通讯录、群聊创建、附件上传/预览/下载逐字节、匿名拒绝、知识库上传检索、云盘上传下载、服务器真实模型任务、SSE/最终 IM/历史全部通过。新租户尚无发布技能，技能装配不能算通过。
- 本机私有模型配置来自用户本机凭据，未写入仓库或其他电脑。

## UI 工具异常（不能算产品通过）

- 原生客户端截图和 AX 树可读；解锁后重复绑定及重置会话，AX 点击数字员工/技能广场均未改变页面；坐标点击报 noWindowsAvailable。按键也未改变界面。
- Chrome DOM 操作正常；管理台登录已经真实执行。后续继续处理原生输入通道问题并验收，不能将服务层结果标为 UI 完成。

用户明确授权改用 Flutter integration_test 驱动真实 macOS UI。测试仅包装实际 CommunityWorkspaceApp 的截图边界，使用真实网络/存储/IM，不 mock Provider、服务、登录或任务；账号夹具仅存本机 ignored 私有文件。

用户随后改为协助手工 UI 验收以加快反馈。原生实际 UI 已打开头像 → 连接服务器弹窗；自动输入未成功，不算连接通过。integration_test 编译中按最新要求停止（No tests ran），保留脚本供后续复用。当前由用户输入并操作，我核对日志与业务结果。

## 10:49 后 UI 回归修复（待用户重开客户端复验）

- 用户手工新建并执行任务，截图可见定时任务卡和真实回复；本机 cron job 3、run_once=true、status=succeeded 与之吻合。新建过程中同时确认 `/cron/prompt-templates` 两次漏路由 404，不把执行成功视为无错误。
- 已接回原 clientcron 列表/变量处理器，追加上游原模板/变量表定义为 000017（旧迁移不变），本机镜像更新、迁移成功；真实登录切租户后列表 HTTP 200 / items=0，匿名 401。UI 新建弹窗需再测。
- 公共员工初次等待直接复用 DigitalEmployeeGallerySkeleton；删除公共目录独立转圈提示；服务器已有卡片和组织/我的分类不被公开目录等待遮挡。
- PromptInput 在社区版统一不渲染底部 AI 提示，覆盖连接服务器后的聊天宿主。加载及服务器 composer 两项定向 widget 回归通过，涉及文件 analyze 无问题，macOS debug 新包构建通过；当前运行进程仍是重建前启动，待重开验证，不声称已完成 UI 复验。
- 用户指出目录/审批/模型控件缺失：当前测试员工实际 execution_locus=cloud；它不覆盖 DSH/Codex 本机执行员工路径，不能用其成功替代后续本机员工配置验收。

## Codex 自行重启并真实 UI 复验（2026-11-13）

已自行结束旧调试进程、启动最新源码，使用 Flutter LiveWidgetController 驱动真实 macOS 控件点击/文字输入；复用完整 CommunityWorkspaceApp、真实服务/Provider/SQLite/IM，无业务服务替身、无 token 注入。验证后保持实际服务器聊天页面，不再把重连交给用户。

- 头像 → 连接服务器 → 输入本机地址 → 检测 → 密码登录成功。
- 通讯录 → 默认部门 → 本机验证成员实际可见。首次 integration_test 停在错误的默认数字员工分类，已修正为点击部门再等成员，不算产品连接失败。
- 数字员工 21 张真实卡片：RenderBox 实测横向 8.0、纵向 8.0 逻辑像素；技能广场 81 张卡片相同。头像与图标截图可见。
- 自动任务 → 新建：真实弹窗打开，未出现 404；本次不创建/执行新任务，不替代先前任务运行记录。
- 返回服务器对话：原社区助手会话及定时任务结果可见；底部“内容由AI生成，请仔细甄别”不存在。
- 本机 /tmp/community-ui-final/checks.json 的 status=passed；五张截图位于同目录。测试入口仅供 opt-in 验证；运行窗口保持登录，磁盘构建恢复正常 main 入口。

本轮没有验收两人互聊和后台 DSH/Codex 配置，不将这些项目标为完成。

## 已有组织员工时的公共目录加载回归（2026-11-13）

- 根因：公共目录与服务器目录独立请求，旧判断只在合并列表为空时展示骨架，组织目录先返回便遮蔽公共加载态。现将 publicTemplatesLoading 经 Host 传到原 Gallery，在全部/官方的同一 Wrap 中追加 4 个原 AgentCardSkeleton；已有卡片保留，组织/我的无公共占位，成功/失败均移除。需求与踩坑文档同步更新。
- 定向 widget 回归覆盖组织先完成、公共等待、四分类切换、成功与错误收尾；连同 gallery 布局共 7 项通过。涉及 4 文件 analyze 无问题；真实 UI 入口 analyze 无问题。
- 自行重启真实 macOS 客户端，再经 UI 登录本机服务器。真实网络请求过程中同时观察到社区助手（组织创建）与 4 个骨架，未使用 Provider/HTTP 替身；截图 /tmp/community-ui-final/02-employees-partial-loading.png。checks.json employeePartialLoadingObserved=true、status=passed。完成后 21 张员工卡片与 81 张技能卡片、8px 双向间距、通讯录成员、新建任务弹窗及移除底部提示再次通过；窗口保留已连接服务器的对话页。
- 正常 main 入口 macOS debug 构建再次通过（/tmp/community-partial-loading-normal-build.log），不保留验证入口为磁盘默认启动入口。未重跑全量 Flutter 或第二里程碑后台验收。

## 里程碑一补验计划

使用两个不同 bundle ID 的真实 macOS 调试客户端隔离账号存储，均通过 UI 连接/登录同一本机服务器。验证通讯录进入人际单聊、双方在线互发唯一文本及离开/返回会话后的历史；服务器任务通过 UI 新建、到期执行及会话结果验收。Flutter LiveWidgetController 只驱动真实控件，不直接调用业务服务，不修改登录凭据/Provider。测试命令与截图保存在本机 /tmp；私有账号从现有 ignored fixture 读取。

## 里程碑一核心流程验收结果（2026-11-13）

### 实际 UI 证据

- 两个独立真实 macOS 客户端：admin 使用原社区 bundle，成员使用临时 bundle cn.qkfintech.zhiban.community.milestone.member（不同偏好设置和缓存）。均经头像 → 连接服务器 → 检测 → 输入账号密码登录，无 Provider/服务替身，无 token 注入。
- 双方通讯录默认部门均展示对方 → 发消息打开同一人际单聊。管理员发 A-1113-01、成员实时收到并回 B-1113-01；修复后再次 A-1113-02 / B-1113-02 双向在线收发；离开/返回及重启后历史仍可见。双方窗口截图位于 /tmp/community-milestone-ui/{admin,member}/09-*-fixed-bidirectional.png，管理员最终历史为 15-final-direct-history.png，已人工查看截图。
- UI 新建“里程碑一服务器调度验收-1113”，原最短间隔校验拒绝 1 分钟后，改为合法 5 分钟创建成功，界面显示 11:35 下次执行。11:34:56 结束创建端进程；服务器 run 4 于 11:35:03 开始、11:35:06 succeeded。随后自行启动客户端，经 UI 登录 → 社区助手，看到定时任务卡、已推送及 SCHEDULE-1113-01 实际回复。截图 10-scheduled-result-after-client-exit.png，历史面板截图 14-task-history.png。
- 测试任务 6b7da4dd-d92d-409c-991b-c2a5cd28cab0 已暂停，保留运行历史。暂停经原 Bus pause API 清理，UI 13-task-paused.png 复核；不把暂停记为 UI 操作通过。用户原任务未改动。

### 真实发现与修复

- 首次打开人际会话，服务器日志明确 POST /chat/conversations/{uuid}/show 缺路由；发消息后 GET .../read-receipts 也缺路由。恢复原 ShowConversationForAccount、原回执 transport/service、同租户/成员及本人消息 sender 校验，MarkRead 接回原 WuKong 临时通知。未增表、未改迁移、未降低授权。
- 实现：community/im/compose.go、receipts.go 注册和装配；clientchat/message_receipts.go 直接移植原 handler；community-bus 原 MarkRead 装配归到同一 IM 模块，避免重复注册。回执 handler 测试直接移植上游，路由安全测试补匿名/错误 scope/非活跃成员。
- 本机只重建 Bus，旧镜像保留 zhiban-community:before-milestone1-20261113。新版 image sha256:3d15527850328b5d899e33cbf4f6ea780709777d0eeae0319535f51a024cf9db；依赖、数据库及其他服务不重建。UI 从通讯录重新打开和发送均无原 404。
- 辅助安全证据：双方查询自己的 seq 返回 HTTP 200、read_count=1/all_read=true；成员查管理员所发 seq → 403；成员 show 管理员独有员工会话 → 403；匿名回执 → 401。/tmp/community-milestone-receipts-security.json。后续复核：不能将旧 UI 回登录页直接归因于辅助 HTTP 登录。login_sessions 显示 macOS 会话被同类 UI 重登录以 device_relogin 撤销，空设备类型的辅助 HTTP 会话独立存在。管理员通过 UI 重登录恢复；另有过期后的 401，续期失败具体原因待单独确认。

### 留跑异常和实际边界（不隐藏）

- 周期任务留跑 5 次：4 succeeded，1 failed（run 6，12:04:06–12:04:24，chat.runtime_stream_failed，任务错误 agent execution failed）。该次原始底层流异常未持久化，不能声称已经修复或精确归因为模型网关。
- pmset 证据：11:36:45 Clamshell Sleep，之后多次 DarkWake；失败那次 12:03:45 DarkWake，12:04:08 再进入 Sleep。错过调度与失败发生在本机后端宿主合盖休眠期间；休眠与失败重合是已证实事实，具体流异常由休眠导致仍属于推断。/tmp/community-milestone-sleep-evidence.txt。没有改变系统电源设置或用自动重试覆盖失败记录。
- 四项核心 UI 路径已通过；不据此宣称睡眠宿主能持续提供服务器服务，或周期任务长期零失败。第二里程碑、全量 Flutter、正式发布、Windows 未验收。

### 验证

- go test ./internal/community/im ./internal/transport/http/clientchat ./internal/service/messagereceipts ./cmd/community-bus 通过（messagereceipts/cmd 本身无本仓测试）。
- go vet ./internal/community/im ./internal/transport/http/clientchat ./cmd/community-bus 通过。
- Flutter 真实 UI 驱动入口 community_milestone_live.dart analyze 通过；正常 main 入口 macOS debug build 通过。UI 驱动脚本在长时间后台/宿主休眠后出现命令超时，追加的清醒后立即执行尝试没有实际发出，不计入成功次数。已有核心流程证据不依赖该追加尝试。

## 登录被测试干扰的复核（2026-11-13）

测试重启/重连使用原社区版 bundle 和管理员账号，工作区切换调用 clearSessionStorage；同账号 macOS 新登录会撤销旧 macOS 会话。数据库可见 11:26、11:47、13:22 的 device_relogin 记录。不能把这种测试流程造成的重新登录交付给用户承担；后续账号及主客户端 bundle 均需独立隔离，普通功能回归不重连用户窗口。日志另外出现 access 过期后的连续 401，但没有足够证据确认续期失败原因，不能归因于睡眠或假定辅助 HTTP 登录踢端。

## 自动续期修复与独立账号验收（2026-11-13）

- 已确认根因：登录后原 UI 会自动切租户；SwitchScope 不返回/不轮换 refreshToken，_persistLoginResult 却删除了本地 refresh。access 到期 401 后，TokenRefresher 在本地判定缺少 refresh，直接 invalid，因而日志没有实际 refresh 请求。与测试重登录产生 device_relogin 是两个独立原因。
- 修复 auth_api.dart：只有 switchToTenantApi 显式 preserveSessionRefresh，同一 aid/sid 校验通过后保留当前 refresh；普通登录缺字段仍清除旧 refresh，身份/会话不匹配或缺 sid 拒绝保存。服务端权限、token TTL、撤销规则不变。
- 联调只用 account 2（本机验证成员），独立 bundle cn.qkfintech.zhiban.community.refresh.verification，独立偏好设置；未登录 account 1，未重启 PID 3498 管理员窗口。测试客户端 PID 11661，正常 main 构建另行恢复，验证结束关闭独立测试窗口。
- 非 mock 真实 Bus 回归：登录 → switchToTenantApi → refresh 保留 → 单次请求带失效 access → 真实 401 → 原续期端点轮换 → 原请求自动重放 HTTP 200 → auth/me 200，通过。fixture 仅从 ignored 私有路径读取，不输出 token。
- 真实 macOS UI：经头像连接本机、成员账号登录及自动选租户；仅在独立进程的下一次 contacts/tree 请求注入无效 access，原服务器实际返回 401。通讯录自动重试后默认部门/成员正常可见，未返回登录页，refresh 已轮换。/tmp/community-refresh-ui/member/refresh-check.json status=passed；截图 renewed-contacts.png 已查看。此为确定性触发真实 401 的续期验证，没有等待自然 15 分钟到期，也没有伪造有效响应或延长时效。
- 保留现有并发单飞、持久化后成功、工作区切换晚响应隔离与请求重放核心回归；本次不修复与此不同的模型流异常，也不重复全量 UI/Flutter/Windows 验收。
- 已被旧代码删除的 refresh 无法凭空恢复。当前管理员窗口保持原进程，不强制重启/登录；修复构建将在后续启动使用，旧会话若已缺凭据需正常登录后才能建立续期能力。

本次最终验证：11 项 client 会话/切换回归通过；3 项 core 并发续期/持久化/重放回归通过；独立成员真实 Bus 401 续期回归 1 项通过；修复文件、测试及独立 UI 入口 analyze 通过；正常 main 入口 macOS debug build 通过。UI 注入只修改一次无效 Authorization，服务端真实返回 401，随后刷新和重放走生产实现。管理员账户在本轮开始后（13:40 起）新增登录 0、撤销 0，PID 3498 未重启。测试独立窗口退出后管理员窗口保留。需求与踩坑文档同步。

## 2026-11-13 下午：当前源码里程碑一重新验收（进行中）

本轮重新通过独立 member / peer 账号和独立 bundle 连接本机服务，禁止使用管理员账号。账号夹具准备仅为测试前置，不计为后台账号创建验收。连接、通讯录、双向聊天、UI 新建服务器任务/关闭创建端后到期执行/重连查看结果分别取新截图和服务记录。增加用户要求的 macOS 本地通知：后台收到人际消息和任务结果、点击系统通知进入对应会话；应用内红点、请求 native notify 与实际系统通知呈现分别判定。测试任务完成后通过 UI 暂停，不改用户已有任务。

### 通知范围核对

检查原 cron/service.go publishRunEvent 的明确约定（2026-08-25）：任务成功/失败均不推系统通知/未读，结果只进历史与任务状态。本轮不把这项既有静默行为当缺陷，也不自行改成提醒；系统通知验收以人际消息为对象。共享屏幕时关闭通知为系统原设置，用户已明确允许临时改成允许通知用于横幅/点击验收，结束必须恢复。

### 下午复验最终证据

- 两个独立测试成员：account 2 本机验证成员、account 3 里程碑验证乙；独立 bundle cn.qkfintech.zhiban.community.m1recheck.member / peer。account 3 仅通过本机测试夹具事务准备基础账号与既有租户成员，使用正式 Argon2id 参数；不算后台开户 UI 验收。未登录管理员账号、未改管理员凭据/成员/任务。
- 两个成员均经真实社区版头像 → 连接服务器 → 检测 18080 → 输入各自既有夹具密码 → 自动选租户。成员 A 的通讯录实际看到 B，B 看到 A，分别点发消息进入同一单聊。
- A UI 发 M1-A-1113-1541，B UI 收到并回复 M1-B-1113-1541，A UI 收到；退出测试进程后重开仍看到两条历史。证据 /tmp/community-milestone-recheck-20261113/{member,peer}/03-*、04-*，最终 14-final-direct-history.png。
- A UI 新建“里程碑1复验-服务器执行-1544”，合法 5 分钟频率，真实社区助手执行，提示只回复 M1-SERVER-1544。job id=5，uuid=0ed26a2e-61d4-492a-9202-757e3eef6da2。15:48:19 结束创建端全部测试进程；15:50:04–15:50:06.773 的 run 10 succeeded，15:55 的 run 11 也在创建端退出期间成功。重连 UI 会话看到对应 15:50、15:55 的任务卡、已推送及真实模型回复，截图 member/09-offline-scheduled-result.png 已查看。
- 本轮 run 9–17 共 9 次全部 succeeded（8 次 cron + 1 次 UI 立即执行），最后一次 16:20；无自动重试覆盖失败。/tmp/community-milestone-recheck-20261113/server-task-runs.txt 保存服务端状态。
- 测试结束用账号 2 的原有会话通过正式 pause API 清理仅 job 5（token 的 aid 校验为 2，未另行登录）；UI 刷新看到已暂停，截图 member/13-test-task-paused.png。暂停是 API 清理、UI 复核，不记为 UI 写操作通过。既有 job 3/4 未改。
- 人际通知：B 从 UI 给 A 发 M1-FINAL-1615；16:13:51.559 收到真实 macOS nativeDelivered；用户明确回复“已看到并点击”，16:14:41.115 同一 identifier/body 的 nativeClicked 回调；随后仅取 UI snapshot、未导航，当前页已从通讯录跳到里程碑验证乙聊天，未读消失。member/12-clicked-notification-chat.png 已查看。原生审计只增量监听 local_notifier，未替换发送/点击处理器或伪造事件。
- 任务结果不发系统通知为现有 service/cron/service.go publishRunEvent 的明确静默约定，非本轮漏通知缺陷；本轮不改变产品提醒规则。

### 本轮工具和验证异常清单

1. 初始 compose 文件名、少数诊断 SQL 字段名不匹配；读取实际 compose/schema 后改正查询。没有为诊断新增表或跑迁移。
2. 直接起二进制后又 open 会产生两个同 bundle 的测试实例，UI 与系统点击可能落在不同实例。只结束本轮实例；区分 CFBundleName、显式注册独立 bundle，每个身份只保留一个进程，登录仍走原 UI。
3. LiveWidgetController.pump 等待真实 endOfFrame，后台不可绘制时命令循环可能停住。驱动空闲改普通延时，执行操作前用原 bringToFront 激活自己的窗口；没有修改 Provider、HTTP、登录或业务响应。
4. CUA 的 fn 键不支持（keyNotFound），系统菜单/通知中心多次 timeoutReached / noWindowsAvailable，通知观察曾选中日历小组件；不算产品失败。最终由用户实际点击通知 + 原生回调 + UI 跳转闭环验收，未伪造鼠标点击结果。
5. 系统原设置“共享屏幕时关闭通知”可能抑制横幅；获用户明确授权后临时选择允许，并读到新值。恢复设置时 CUA 连续三次超时，用户随后说“你别管这个通知了”；因此停止操作，恢复状态未确认。不能以 nativeDelivered 单独声称已看到横幅。
6. 尝试点击任务卡图标未改变启用状态，不算 UI 暂停成功；最终采用上文正式 API 清理并 UI 复核。

### 本轮验证与未运行项

- Go 窄回归 go test ./internal/community/im ./internal/transport/http/clientchat ./internal/service/messagereceipts ./cmd/community-bus 通过，后两包无独立测试。
- 真实 UI 驱动入口 dart analyze 通过；正常 main 的 macOS debug build 另行恢复，结果见 /tmp/community-m1-recheck-normal-build.log。
- 本轮仅改 opt-in 验收脚本、其测试依赖和验证记录，未修改业务逻辑或数据库结构；先前已在工作区的修复仍保留。
- 未重复全量 Flutter / 全服务测试，未验收 Windows、移动端、跨电脑/公网、正式签名包、第二里程碑或宿主睡眠持续调度。历史一次休眠重合的流失败仍是历史未定位项，本轮 9 次成功不能抹去它。


## 本地提交前复核（2026-11-13）

- 桌面端本次改动的 5 个测试文件：79 项通过。
- 共享客户端本次改动及新增加载态测试：首次 324 通过、12 跳过、1 失败。失败为会议邀请入口测试误查 Tooltip 外层 GestureDetector；实际入口为内部 InkWell。改为验证真实 InkWell 的非空 onTap，整个 RTC 文件复跑 23 项通过；合计当前覆盖 325 个通过用例、12 个显式能力边界跳过。没有将此定向结果记为全量 Flutter 通过。
- 涉及的共享实现、加载态/真实续期测试及 4 个原生 UI 驱动静态分析通过。初次 3 条大括号风格提示已修正，并定向复查。
- Go community 全包、clientchat、messagereceipts、community-bus 定向 test/vet 通过（后两包无测试文件）。本次不重复执行数据库迁移、Docker 构建或真实账号登录。
- 原隔离候选运行时源码与当前 5 个改动源文件逐字节一致，使用其既有开发依赖重新执行 tsc 通过；实际随包 Node 执行 runtime/attachments/Codex 错误信息测试共 26 项通过。
- 仓库运行时目录没有完整开发依赖，直接 npm build 报缺 @types/node；系统 Homebrew Node 跑隔离用例报 local.isolation_unavailable。改用现有隔离候选依赖和正式随包 Node 完成上项检查，未安装依赖或放宽隔离策略。
- 原生交互采用上文已完成的实机 UI 证据，本提交阶段未重新启动/登录客户端，未干扰用户会话。第二里程碑及 Codex 偶发历史续答问题仍按原记录保留，未宣称修复。
- .dart_tool 和运行时 dist 纳入忽略；core 验证产生的无关锁文件升级已还原。私有夹具、模型 Key、生成包及 /tmp 截图/日志不提交。检查待提交源文件未发现长 sk- Key 或私钥块。暂存区 diff --check 仅报告原样引入且已在本机执行的 000014 SQL 末尾多一个空行；保留原字节避免迁移校验和改变，其余文件通过。社区仓库没有 check-repo-hygiene.sh，未执行该脚本。
