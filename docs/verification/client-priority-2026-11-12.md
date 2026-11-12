# 客户端优先修复与验证（2026-11-12）

用户要求优先保证客户端可用，暂停完整后台扩展。已有后台改动保留，后台后续仅围绕客户端必需管理能力确定范围。需求见[服务器工作区](../requirements/server-workspace.md)，部署与验收遵循[联调规范](../standards/server-workspace-integration.md)。

## 真实模型与原生操作补验

用户已在运行中的 macOS 客户端填写模型 Key，并明确允许用于本机测试服务器。复用现有模型服务、本地执行器和服务端 OpenAI 兼容配置；凭据只进入已忽略的本机配置，不进入源码、测试输出或文档。本地和服务器的验证分别记录，不自动同步其他配置或数据。

已在真实原生窗口完成：模型检测提示密钥可用；创建临时员工；选择 minimax-m3；算术首轮返回 1591；续轮通过历史读取工具返回前轮标记及 8051；选择临时工作目录，真实工具读取 input.txt、写入并回读 result.txt，磁盘内容为 `ZB-FILE-1112: 485`；原生文件选择器添加文本附件，模型读取标记并回答 899；聊天历史侧栏显示真实消息；原生创建暂停任务、立即执行两次，历史均显示成功且返回 3599；编辑保存和删除临时任务；技能广场详情、下载并装配“项目周报生成”、使用后聊天技能栏可见。

截图和临时脚本位于本机 `/tmp/zhiban-native-*`，其中模型页 Key 始终掩码。后续仍须补齐其余原生操作和服务器真实模型链路，不能把以上结果扩大为全部页面通过。

## 修复

- 原 Bus 附件上传、确认、下载/预览与聊天媒体处理器抽为 `clientfiles`，两入口委托同一实现，社区装配原存储、服务及附件绑定器。修复当前源码附件/媒体 404。
- 原职位处理器抽为 `clientpositions`，显式注册 `/agents/positions`，避免被员工详情路由捕获返回 500；真实租户字典为空，不插入种子。
- 原群聊/人际单聊处理器抽为 `clientrooms`，社区复用原 room/directroom 服务、联系人可见性及 WuKong provisioner。保留原协议，`GET /rooms` 非列表接口，返回 405。
- 原技能能力/绑定 DTO、会话技能栏、临时覆盖和内置技能握手处理器移入 `clientcatalog` 公共实现。修复社区一律关闭装配标志与人机 room 会话技能栏 404。账号归属、会话访问、同租户和成员授权保留。
- 社区模型选择维持关闭；商业 BeeBridge `/llm-models` 未进入公共闭包，不提供虚构列表。公共技能仍只浏览，当前服务器技能沿原装配流程。
- 内网同步公共处理器及原 Bus 委托，公开清单显式包含所需包；未暂存文件仍存在，不能声称已完成可重复的干净导出。

## 已执行验证

| 范围 | 证据与结果 |
| --- | --- |
| 当前源码真实客户端 | 原有 desktop 部署临时运行新 Bus：密码登录、租户、员工/联系人、职位读取通过；两位临时员工创建/删除通过 |
| 技能装配 | desktop 现有技能绑定、列表/详情能力与绑定回读、room 人机直聊技能栏通过；E2E 租户无技能，该环境未验证装配 |
| IM 与聊天 | 真实 Flutter WuKong SDK 建连、群发送确认、人机消息发送、SSE、最终 IM 回复、历史回读通过；回复为 Mock |
| 附件与媒体 | 真实 multipart 上传、群/人机媒体引用、四条下载/预览签名地址、对象内容逐字节一致、匿名 401 通过 |
| 隔离 | 原有 E2E 两租户用新 scope token 验证群/附件跨租户拒绝；desktop 仅一个租户不重复此项 |
| 知识库 | desktop 创建临时个人 KB、文本上传、检索标记、删除通过 |
| 网盘 | desktop bootstrap、上传、签名下载逐字节一致、删除通过 |
| 自动任务 | desktop 创建、立即执行、轮询成功终态、删除通过 |
| Go | 社区触及包及上游原 Bus/clientcatalog/community/room/directroom 定向测试、vet 通过；im/room/directroom race 通过；19 个恢复路由的匿名/平台 scope/非成员拒绝回归通过 |
| Flutter | 工作区/员工来源 6 项、会话/连接/未读/缓存 161 项、本地及聊天/技能/媒体扩展 131 项通过；另 37 项本地定向测试与后组重叠，不相加为独立数量 |
| macOS | `flutter build macos --debug --no-pub --dart-define=COMMUNITY_EDITION=true --dart-define=COMMUNITY_SKILLS_BASE_URL=https://zb.qkfintech.cn` 通过 |
| Dart 静态检查 | 桌面入口、连接/会话、聊天/员工/本地工作区等已修改 Dart 文件定向 analyze 通过，无问题 |
| 本机运行时 | 使用 App 实际打包的 Node/DSH/Codex 运行两组测试，22 项通过，覆盖工具策略、文件/shell、历史续答与取消；模型为确定性测试响应 |
| 原生页面 | 原生登录成功，服务器聊天/历史可见，头像菜单返回本地，官方员工目录/图片可见 |
| 公开闭包 | 新公共文件内容扫描与内网模块路径替换后一致；六入口 source closure 含模块 overlay 清单覆盖，后端依赖扫描无禁止依赖 |

实时测试只从现有本机 fixture 读取凭据，不读取桌面保存的开发凭据，不将凭据写入文档。临时员工、KB、任务及网盘文件按业务 API 删除；标记聊天/审计记录保留，原软删除语义不变。

本机日志：`/tmp/zhiban-client-desktop-candidate-live.log`、`/tmp/zhiban-client-current-source-live.log`、`/tmp/zhiban-client-priority-upstream-final.log`、`/tmp/zhiban-client-priority-macos-build.log`、`/tmp/zhiban-client-priority-runtime-tests.log`。日志可能含测试业务内容，仅本机保存。

## 限制

- 真实付费模型回答、全部岗位技能业务结果、电话/第三方工具、全端完整原生点击未在本轮验收；没有为验收读取或上传本地模型 Key。
- 技能临时覆盖/握手恢复了原处理器并验证授权拒绝，但本轮未单独验证真实成功写入；人际单聊完成原服务测试，未做两位真人原生互聊。
- 验证复用已有数据库，当前原始 13 份迁移的全新安装未验证。未创建数据库、执行迁移、修改表结构/账本或补权限种子。
- 本轮未跑全仓 Go/Flutter 测试或正式安装包签名发布；定向结果不能等同全部客户端功能通过。
- 后台扩展暂停，历史全部菜单可见并不代表业务全部可用。

## 持久运行状态

现有 desktop Bus 已固化为独立本地镜像 `zhiban-community-desktop-bus:client-20261112`，使用原 Compose 仅重建 Bus，修复保留。真实登录、技能绑定、群聊/SDK、附件、KB、网盘和任务全流程再次通过。运行 `/proc/1/exe` SHA-256 为 `4fd3b0de9aee5900c162a341c393a871baae84f01291a1d4469bd47692e29bd3`，与重新编译及临时验证产物一致。

镜像摘要：`sha256:a5e3c05183b4e0c7e2e6fc4d4eeb898c4428dd5c2ca3888d27293ad01a55a479`。原配置/程序备份：`/var/folders/1g/z1x9jghd70327nz57bn2b_h80000gn/T/zhiban-client-persistent-backup-fz04zofv`。迁移账本摘要及其他 desktop 服务容器 ID 前后一致，原始 13 份迁移源码无变更。现有 E2E Bus 保持恢复状态；E2E Admin 摘要为 `7c0336a41aa42f33f6d96b67eb860c653f74b171d3dc54eda74b6a244fc594cd`，匿名身份探针 401，程序已恢复。

持久部署后日志：`/tmp/zhiban-client-persistent-live.log`。未更新 Admin、worker、数据库、Redis、对象存储或 IM 容器。
