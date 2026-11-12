> 2026-11-12：本文件为历史版本验收记录。本轮已撤销额外 SQL、后台页面及配套扩展实现，下文的安装、邀请、模型注册表、群聊扩展和外部知识库验收不代表当前源码。当前范围见 [复用核对](../architecture/community-schema-reuse.md)。

# 服务器工作区真实部署联调（2026-11-11）

环境：macOS、Docker Compose、Go 1.27.1、当前 Flutter 工具链。使用公开社区源码构建 Linux arm64 Bus/Admin/worker/迁移/初始化程序；PostgreSQL、Redis、MinIO 与真实 WuKongIM v1.2.6 独立运行。WuKong 官方镜像在当前网络下使用已缓存的 docker.1ms.run 镜像副本（amd64 仿真），未据此验收官方镜像下载或其他平台。

## 改动

- 先扩展服务器工作区需求，明确真实依赖验收和 Mock 边界；同步 README、INSTALL、部署说明与踩坑。
- 社区 Bus 装配已有 ChatUploadSvc/ChatMediaSvc，注册上传、presign/confirm、附件与媒体授权读取路由，设置 128 MiB 上传限制、严格有界 JSON、multipart 临时文件清理和签名读取禁止缓存。
- 聊天注入附件绑定和会话清空水位；挂载已有会话隐藏/显示、置顶、免打扰、未读操作。
- 追加 000014–000021 社区迁移：技能策略/握手、知识库容量计数、PostgreSQL 文本分片和召回日志。保留已有迁移校验和。修复召回日志可空会话 UUID 的 SQL 显式类型转换。
- 新增显式启用的 Flutter 双进程实时联调用例，以及独立环境创建/运行/清理脚本。默认普通 flutter test 跳过实时用例。
- 修复公共广场随服务器地址切换的问题：员工/技能目录使用独立匿名客户端；公共模板可建立当前服务器个人员工，公共技能直接选择员工后安装租户副本和正式绑定。头像菜单统一连接、返回本地、地址与接入指南。
- 补齐模型目录与技能装配标记，平台技能导入/编辑/删除及包资源投影；投影失败不能发布损坏版本。
- 装配人际单聊和群管理服务，修复邀请前授权、direct 不隐式升级、成员字段脱敏；群 @员工启用已有持久任务队列和最终 IM outbox。
- 补齐普通成员邀请、一次性临时凭据、客户端/管理台首次改密；Bus 全部业务入口拒绝 mc token。追加 tenant.member.invite 权限迁移覆盖既有租户。
- 显式启用 WuKong token 校验；成员停用/移除轮换 App/Web/Desktop token 后踢线。修复 SDK 解析 v1.2.6 鉴权失败 CONNACK 时越界读取 nodeId。

## 结果

| 场景 | 结果/证据 |
| --- | --- |
| 空库迁移与再次执行 | 两次成功；使用唯一项目、独立卷 |
| 管理员初始化与建租户 | stdin 随机密码；Admin API 创建两个租户 |
| 客户端匿名检测、密码登录、租户切换 | 真实 Auth API 与客户端 Service 通过 |
| 员工列表/详情、通讯录 | 真实客户端 Service 通过；个人员工创建/编辑回读、绑定技能名称及文本运行通过 |
| 模型目录与空员工重建 | /llm-models 返回当前配置；删除租户员工至空后仍能选择运行环境、重建及发布 |
| 公共员工/技能目录 | 匿名生产接口返回 20 员工 / 81 技能；定向测试证明服务器连接不改变目录源、不带登录凭据，失败保留错误和可重试态 |
| 平台技能 | 有效 bundle 导入、发布、重复导入 skipped、编辑、删除通过；租户管理员导入返回 403 |
| 成员接入 | 真实 Admin Invite 建两位普通成员；临时密码登录后业务拒绝、改密、旧会话 401、新密码登录、无后台邀请权限；重复邀请 409，跨租户复用不返回密码 |
| 人际单聊/群管理 | 双向幂等单聊、群创建/改名/邀请/移除、成员自退授权单测、非群主/非成员/隐藏联系人/禁邀/跨租户/历史拒绝 |
| 群实时消息 | 两个独立 Flutter 进程、真实普通成员 SDK 收发；群 @员工 final 回复到达，数据库 task=done、outbox=sent |
| 成员移除 IM 撤销 | 已连接成员被移除后断线，原连接信息再次登录失败，新 IM 凭据请求 403；真实鉴权拒绝 CONNACK 无解析异常 |
| 管理台邀请界面 | Chromium 1366×768：进入成员页、抽屉填写/提交、成功后临时密码默认掩码、关闭后列表刷新通过；无页面 JS 异常 |
| 员工单聊 | 真实 WuKong SDK WebSocket、发送确认、prepare/attach、SSE 终态与最终 IM 通过；按本次 stream_id 匹配 final，模型为 Mock |
| 断线重连与历史 | 真实断开/重连、聊天历史读取通过 |
| 会话菜单 | 置顶/免打扰/标未读/已读、隐藏/显示、清空后历史为空通过 |
| 附件与媒体引用 | 上传、下载字节一致、绑定消息、创建会话引用、读取通过；签名响应 no-store |
| 文件权限 | 未登录 401、同账号切另一租户 403；无下载重定向 |
| 云盘 | personal bootstrap、上传、签名下载字节一致、删除通过 |
| 自动任务 | 新建、立即执行、轮询到成功终态、最近记录、删除通过；使用 Mock，不等同真实模型或时钟调度长稳验收 |
| 知识库 | 新建、文本上传 ready、文本检索命中、删除通过；额外查询 PG 确认召回日志存在 |
| 退出清理 | 客户端清除 token，IM 不再连接；桌面切换回归确认本地数据保留 |

运行命令（从仓库根）：

    python3 deploy/community/server_workspace_e2e.py --flutter /Users/aigc-build/fvm/default/bin/flutter --wukong-image docker.1ms.run/wukongim/wukongim:v1.2.6

最终完整脚本退出码 0（独立项目 zhiban-workspace-e2e-jim0eiuj），Flutter 实时用例 2 passed，额外空库/重复迁移/队列完成/最终 IM/召回日志检查通过。脚本使用随机回环端口与私有临时目录，不读取开发者现有 .env、桌面库或个人模型 Key；默认运行后清理本次容器和卷；排障期间以 --keep 保留的本次独立项目在诊断后单独清理。第一次脚本增加落库断言时曾暴露召回日志 UUID 类型错误，修复后全新空库重跑通过。

其他验证：

- Go：go test ./internal/transport/http/clientfiles ./internal/community/... ./internal/service/knowledge/... ./cmd/community-bus ./cmd/community-migrate 通过。新增路由测试覆盖可信身份传递、JSON/大小拒绝、签名禁止缓存、拒绝读取无重定向、八条路由统一鉴权。
- Go：go vet ./internal/transport/http/clientfiles ./internal/community/drive ./cmd/community-bus 通过。
- Flutter：analyze test/server_workspace_live_test.dart 无问题；连接、弹窗、通讯录缓存、会话清理、本地控制器定向回归 19 tests passed。
- 桌面：flutter test test/community_workspace_switch_test.dart，1 passed。
- 文档/差异：检查本次 Markdown 本地链接、Python 语法和 git diff --check。

## 实际限制与未跑项

- 没有真实服务商 Key，未调用真实付费模型；Mock 只证明平台与投递链路。部署注册表和管理台模型选择/发布已验证，模型请求与清空上下文通过隔离 HTTP 服务捕获验证；真实服务商 HTTPS/付费推理、外部运行时、工具执行、向量 RAG、OAuth/第三方应用、音视频须单独配置验收。
- /llm-models、个人员工装配、平台技能、人际单聊/建群与群 @员工已补齐上述验收。未配 issuer 时 /workspace/apps 仍不注册；全部设置页面、复杂群策略、多 Agent 协作等未逐项验收。
- 技能文本和资源投影闭环已验证；公共广场独立读取公开目录，添加后生成当前租户副本并绑定员工，持久部署已有两项验收技能。脚本执行、二进制及第三方工具后端仍需相应运行时验收。
- 先前 skill 测试缺少未公开的 fixture；现已改为公开仓库已有 fake/projector，保留投影失败拒绝和回滚断言，go test ./internal/service/skill 通过。
- 未运行全仓库测试或发布构建。已重新构建当前 macOS Debug App（含连接菜单、公共目录、改密和 IM 解析修复），没有替换已安装的正式 App 或更新 Release/DMG。未跑 Windows、移动端、生产 HTTPS/跨机器/高负载与故障恢复验收。
- 本公开仓库没有 scripts/check-repo-hygiene.sh，使用定向差异、生成物与凭据检查；未虚构该命令通过。

## 此电脑持久部署

按用户要求，在此 Mac 新建独立项目 zhiban-community-desktop，保留旧项目与卷。配置、登录信息、JWT 和加密密钥位于 Git 忽略的 deploy/community/.local/desktop（目录 0700，含口令的文件 0600）；容器所需只读配置和 JWT 文件允许容器 UID 读取。镜像构建上下文仅包含编译程序，不包含配置或凭据。

- Bus 38080、Admin API 38081、管理台 38082、WuKong WS 38083、对象存储 39000，均只绑定 127.0.0.1。
- PostgreSQL、Redis（AOF）、MinIO、WuKong 使用独立命名卷；九个常驻容器设置 unless-stopped。电脑重启后需先启动 Docker Desktop。
- 当前源码编译六个 Linux arm64 服务程序，覆盖缓存运行时镜像中的对应程序；空库迁移和 stdin 初始化管理员成功，Admin API 创建“我的工作空间”。
- Node 24.19.0 从镜像源下载后与官方 SHA256 清单核对；pnpm 10.32.1 frozen-lockfile 安装、pnpm lint、pnpm build 通过，当前管理台产物由 Nginx 提供。
- 管理台 HTML、静态资源和代理密码登录通过；真实 Flutter Auth/员工/通讯录/WuKong SDK 发送/SSE/final/重连/退出的定向冒烟通过（1 test）。不读取桌面已有凭据或改动本地数据库。
- 重启 Bus/Admin/worker/audit-writer 后，再次密码登录与切换租户成功，已有会话及至少两条历史消息仍可读取；本轮未重启整机或 Docker Desktop。

本地启停工具是私有目录中的 manage.sh，支持 start、stop、status；stop 保留卷与密钥。登录信息同目录保存，仅供本机用户查看，不进入公开文档。默认助手仍为 Mock，真实模型与其他能力的限制同上。

后续升级：当前六个服务二进制已重编译到本机镜像，000014–000021 迁移成功；Bus/Admin/worker/audit-writer/WuKong 已更新，原命名卷保留。管理台新静态文件已部署到 38082，WuKong 显式启用 token 校验。升级后真实密码登录、租户切换、员工 1 个、模型 1 个、通讯录 1 人及既有会话可读；独立 Flutter 冒烟完成真实鉴权 SDK 发送、SSE、最终 IM 和历史读取（1 passed）。本服务器技能数 0，不影响公共广场。

## 本轮追加验证命令

### 应用 OAuth 协议与授权生命周期

- 独立项目 zhiban-workspace-e2e-3eywy2xl 完整联调退出码 0，真实 Flutter/SDK 2 项通过；临时容器和卷清理，原持久部署保留。新增真实 Admin 创建、Bus 列表/员工绑定/启动、Discovery/JWKS、RS256 验签、code 一次性消费和 refresh 轮换；错误 redirect/跨 client 不消耗合法凭据，重放、跨租户、租户停用、scope 收回、成员移除后旧 code/refresh 拒绝。
- 单测先复现成员移除仍签身份、共享会话非创建者换码失败；修复后应用服务/客户端应用接口、社区装配与 community-bus/admin 定向 go test / go vet 通过，覆盖身份/应用生命周期与读取失败默认拒绝。
- issuer 配置为 HTTPS 元数据，实际通过本机回环 HTTP 访问；未访问虚拟 H5 callback，不能宣称浏览器 H5、生产 TLS 或第三方业务 API 通过。当前持久部署未配置 issuer，本轮 OAuth 源码未部署到该实例。

### 工作台应用启动补验

- 独立项目 zhiban-workspace-e2e-q5a84uhm 完整脚本退出 0，真实 Flutter/SDK 2 项通过；新增工作台 oauth2 入口、无会话 launch/code 换码、JWKS 验签、身份/租户/nonce 一致和 zhiban_context 缺省，跨租户及非通用应用启动拒绝。既有员工绑定、禁用、scope 收回与成员移除继续通过，临时项目清理完成。
- 工作台调用原 AppsBusService，无会话启动由服务端检查当前身份、应用/client 与通用开关；不再向任意应用 URL 拼接 dashboard token。工作台保留标签页、Flutter 路由与兼容 web 链接；OAuth 失败不打开原始地址，重复点击不重复申请。
- Flutter 工作台 5 项通过：真实组件点击/防重/失败提示，调用既有服务、无会话/随机 state/nonce、拒绝非法链接、禁止原始地址回退及旧链接无凭据；相邻聊天应用 3 项通过。静态 analyze 通过；桌面员工来源 3 项再次通过。Go app/clientapps 定向测试、仓储编译与 vet 通过。macOS Debug 构建通过，未验收原生工作台 H5 页面、Release/DMG、Windows、移动端、生产 TLS 或第三方资源 API。
- 桌面再次原生登录持久服务器并点击员工分类：组织显示“社区助手”，我的显示“技能安装验收助手”与两项技能，全部合并公共模板和服务器员工，无常驻刷新按钮；保留当前我的页面。新 Debug 的 App.framework 严格验签通过，按原 entitlements 更新外层 seal 后整包严格验签通过。本次没有重启或替换正式安装包。

### 未读、公共技能与桌面排版追加验收

- 模型/上下文扩展已在独立项目 zhiban-workspace-e2e-6yus9rxx 重跑完整脚本通过，含 2 个真实 Flutter 实时用例；浏览器管理台创建/编辑/回读模型选择并发布通过。公共直接安装及最新未读/UI 修复在此后使用下面的定向验证，没有再次运行完整隔离部署。
- 原生 macOS Debug 复现当前“社区助手”已显示消息而 Bus unread_count=1；修复后重新连接/登录自动恢复同一会话，侧栏徽标消失，Bus unread_count=0，数据库 last_read_at 从 08:22:09 UTC 推进到 08:51:28 UTC。未通过直接 API 标读或数据库更新掩盖问题。
- Flutter 实时桥、未读竞态与技能选择器 146 项通过；追加“列表在标读期间开始、确认后才返回”竞态后，未读文件 11 项通过。更大流式回归 200 项通过、2 项失败：RTC 测试取消事件缺插件桩、模型错误文案断言未包含稳定错误码；没有修改无关业务绕过。
- 公共技能真实固定源摘要校验、重复安装、租户目录与员工绑定回读、匿名/未知字段拒绝通过；授权/摘要失败通过 Go 定向测试。原生公共广场点击“项目周报生成→添加→员工”后按钮变为“使用”，当前服务器目录和员工详情均回读该正式绑定；未出现保存文件窗口。删除本任务误建的两个重复验收员工，保留一个装配验收员工。
- 技能页去掉常驻刷新和独立工作区切换行，页头/筛选/卡片整体上移。公共员工复用原 OpenClawDigitalEmployeeGallery 和详情壳，保持搜索行、来源筛选和网格间距；原生检查公共/当前服务器的员工与技能页面、详情和添加成功状态。
- 画廊布局、公共目录 Provider、技能选择器定向 9 项通过；共享客户端与桌面页面 analyze 无问题，macOS Debug 构建通过。员工打开聊天扩展文件停在旧 ChatDetailHeader 用例，等待超过三分钟后终止，未计为通过。
- 末尾去掉未使用刷新参数及补公共员工空态后，画廊/目录/安装/未读合计 20 项通过，共享客户端和桌面页面 analyze 通过，macOS Debug 重建通过。未跑 Release/DMG、Windows、移动端及最新修复后的完整隔离部署脚本。

### 最终桌面与聊天回归补验

- 原生 macOS 再次检查加载完成的技能广场、公共员工和当前服务器员工：无常驻刷新按钮，切换器与页标题同一行；员工复用既有画廊、来源筛选、搜索行与详情组件。当前服务器仍可新建员工，已装两项技能正常显示。
- 员工打开聊天回归此前挂起的原因是服务替身未覆盖缓存入口，误等原生存储；补齐空缓存/历史同步和 IM 替身，完整文件 51 项通过。流式回归注入内存 RTC 控制器，消除跨用例原生事件取消异常；HTTP 400 回归保留失败状态、HTTP 原因、稳定错误码及历史/切换恢复断言，完整文件 56 项通过。
- 执行 flutter test --no-pub：digital_employee_open_chat_test、chat_multi_conversation_stream_test、digital_employee_gallery_layout_test、chat_unread_race_test、server_market_providers_test、skill_install_agent_dialog_test，合计 127 项通过。两个修改的聊天测试文件 dart analyze 无问题。前述 2 项扩展回归失败和员工 header 挂起已解决。
- 最新源码重新运行 deploy/community/server_workspace_e2e.py，独立项目 zhiban-workspace-e2e-bfer58c3，退出码 0。真实 Flutter 实时用例 2 项通过；邀请/改密/撤销、模型与员工编辑回读、人际与群 SDK、群 @员工队列及最终 IM、附件/云盘字节校验、任务、知识库、越权拒绝、迁移重放和召回审计全部通过。本次临时容器与卷已由脚本清理，持久部署数据保留。
- 本轮追加只修改测试夹具与验收/踩坑文档，沿用已通过的 macOS Debug 构建；没有更新 Release/DMG，也未运行 Windows、移动端和真实付费模型验收。

### 员工能力回显补验

- 先用回归复现三个缺陷：员工详情漏 local_engine、客户端空绑定回退旧标签、联系人转换丢部门。员工投影还缺少 apps[]，已统一列表/详情/保存响应的应用与知识库摘要；兼容标签从正式绑定重建，应用仅公开 uuid/code/name/icon_url。加载失败仍返回 5xx，已移除项不再回写编辑草稿。
- Go test 通过 clientcatalog、communityagent、community/chat、community-bus；go vet 通过 clientcatalog、communityagent 与 community-bus。新增测试检查摘要字段白名单、真实绑定覆盖旧标签、空数组、Codex 引擎与依赖失败拒绝。
- Flutter 相邻回归 102 项通过；核心包 dart test 115 项通过。修改的核心模型与客户端回归文件分别在各自包内 dart analyze 通过。跨包直接 analyze 曾因核心包未解析依赖报 URI 错误，补齐该包依赖后在正确目录检查通过，未修改发布依赖或锁文件。
- 独立项目 zhiban-workspace-e2e-sm5z36av 完整脚本退出码 0，真实 Flutter 实时用例 2 项通过。新增知识库绑定后列表/详情/通讯录与编辑草稿一致、改名不丢绑定、清空后伪造 metadata 不恢复绑定；本地 Codex 员工创建/详情/编辑保持 codex_app_server。其余邀请/改密/撤销、SDK 单聊/群聊/群 @员工、文件/云盘/任务/知识库、迁移和审计继续通过；临时项目已清理。
- macOS Debug 重建通过。本机持久部署只更新 Bus 镜像并保留原卷，真实认证检查已有 2 位员工的列表/详情能力字段通过。应用摘要由服务替身验证，当前持久部署无 OAuth issuer，未据此宣称第三方应用端到端可用。Release/DMG、Windows、移动端及真实付费模型本轮未跑。

- Go test：internal/community/...、internal/im/wukong、internal/service/{room,directroom,chat,wukongagent,skill}、internal/transport/http/{adminorg,adminskills,clientrooms,clientfiles}、cmd/community-{bus,admin}，全部通过；部分装配包没有单测，真实场景由上方独立环境覆盖。
- Go vet：internal/community/...、internal/im/wukong、adminorg/clientrooms 与 community-bus/admin 通过。
- 管理台 pnpm lint / pnpm build 通过；真实浏览器邀请 API 通过。
- Flutter：连接/弹窗/公共目录/通讯录缓存/群员工权限 16 项，改密路由与会话/登录状态 10 项，SDK CONNACK 与连接状态机 10 项，桌面工作区切换 1 项，均通过。相关新增页面、provider、测试 analyze 无问题。SDK 测试通过共享客户端的已解析依赖运行。
- macOS flutter build macos --debug --no-pub 通过；已有 NSUserNotificationCenter 弃用和旧外部构建路径警告未阻断构建。未跑新的公证、安装包、Windows 或移动端。
- git diff --check、Python 语法、文档本地链接与定向未跟踪生成物检查。

### 组织 / 我的空白修正与原始联系人补验

- 根因：公共画廊注入的目录只有 platform，enterprise/personal 固定为空，但仍显示全部来源分类。桌面入口现只保留“全部 / 官方 / 组织 / 我的”，显示层合并匿名公共模板和服务器目录，服务器操作继续由原 DigitalEmployeeGalleryHost 承载。模板以对象来源区分，UUID 相同也不会误走服务器聊天。
- 新增 community_employee_sources_test：3 项通过，覆盖默认合并、组织与个人分类、编辑能力、详情按钮、模板确认、两源搜索，以及公共/服务器各自失败和重试。布局/匿名目录/能力回读相邻回归 12 项通过，原员工打开聊天回归 51 项通过（合计 66 项）。相关共享组件、桌面页和新增测试 analyze 通过，git diff --check 通过。
- macOS Debug 构建通过；App.framework 严格验签通过，外层旧 seal 按原有 entitlements 重签后严格验签通过。仅重启本任务 Debug 预览，实际登录持久服务器后点击组织显示“社区助手”、我的显示“技能安装验收助手”与两项已装技能，官方详情显示“添加到当前服务器”。未运行 Release/DMG、Windows 和移动原生验收。
- 原始 /contacts/agents 回归先失败：本地 Codex 员工 execution_locus 为空；已在 community-bus 启动时装配现有受租户与可见性限制的 ConversationCapabilitiesResolver。修复后独立项目 zhiban-workspace-e2e-sy0s23qq 完整联调退出 0，真实 Flutter/SDK 2 项通过（含原始联系人、KB 绑定与移除、Codex 引擎、两账号群聊、附件/网盘/任务等），空库/重复迁移/队列/outbox/审计验收通过。持久部署仅更新 Bus，保留原数据卷。
- Go：clientcatalog 定向测试通过，contacts/community-bus 编译通过；community-bus vet 通过。公开仓库不含 scripts/check-repo-hygiene.sh，未运行该脚本。
- 针对用户反馈再次复验当前原生 Debug：逐个点击“组织 / 我的”，分别显示“社区助手”和“技能安装验收助手”（含两项已装技能），页面无常驻刷新按钮。重新执行 `flutter test --dart-define=COMMUNITY_EDITION=true test/community_employee_sources_test.dart`，3 项通过；桌面页与测试、公共画廊及业务宿主 `dart analyze` 无问题，`git diff --check` 通过。本次只补验收记录，未重新制作 Release/DMG。

### 应用借用知识库资源接口

- 缺口：社区 Bus 只注册 OAuth 换码和发现接口，kb.read 令牌没有对应资源路由。现注册五条应用只读接口，逐次重查当前 client、应用、scope、租户开关、账号、成员和改密状态；应用资源只接受对应 issuer/audience/kind 的 access_token。补齐 iat/exp 必填及有效区间校验。
- 知识库、文档和检索仅返回公开 DTO，自己的私有库与跨租户拒绝。独立检索入口复用提供方和可见性，保留显式 threshold=0，不写用户 query_text；事件记录能力和路由模板，不记录查询参数或正文。检索 JSON 限 16 KiB，未知字段、尾随 JSON 和非法范围拒绝。
- 首次独立部署 jv37d4hj 真实检索验收失败：PG 路径的切片 UUID 被当作 document_id。已在当前 KB 范围批量映射真实文档 UUID，缺引用时返回失败，并沉淀踩坑。修复后 2qftsxbd 完整脚本退出 0；追加“用检索 document_id 打开文档详情”后，qtjokez0 再次退出 0。真实上传内容、列表/详情/文档/检索、字段白名单、自己的私有库、跨租户、错误令牌类型、缺 scope，以及停用/收 scope/移除成员后旧 access_token 拒绝均通过；审计 events_outbox 落库且不含检索查询正文。两次均包含真实 Flutter/WuKong SDK 2 项及既有文件、群队列/outbox、成员生命周期和迁移回归，测试脚本只清理自身临时容器和卷。
- Go：`go test` / `go vet` 通过 appexternal、app、knowledge 及 provider、knowledge 仓储、OAuth JWT 和 community-bus；相邻 clientknowledge/clientapps/middleware/community 回归通过。`go test -race` 通过 appexternal/app/OAuth JWT；`go test ./... -run '^$'` 全包编译通过（不是全量测试）。Python AST、变更 Markdown 本地链接和 `git diff --check` 通过。
- 文档同步能力需求矩阵、部署说明、联调规范与踩坑。本轮未修改客户端，不重新构建 Release/DMG；持久桌面部署未配置 AppIssuer，未将独立环境资源接口称作已部署到该实例。contacts.read、机器 API Key/runtime token、外部 HTTPS/H5、向量 RAG 与真实供应商仍需后续补齐和验收。
