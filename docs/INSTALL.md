# 社区版启动说明

## 桌面本地使用（默认入口）

客户端默认免登录启动，不需要启动 Docker Compose 或填写 Bus 地址。进入「模型服务」选择服务商并保存自己的 API Key，再新建数字员工即可聊天；服务商顺序保持现有配置。内置模型地址与文本模型沿用目录，必要时可手动修改。

员工、聊天记录和已安装技能信息保存在应用支持目录下的 `community_workspace_v1.db`，不会按旧服务端缓存的 30 天规则清理。备份时先退出客户端，再复制该文件。API Key 以明文独立保存在应用支持目录的 community-credentials 中（模型为 .key 文件，工具为 tools/*.json），不包含在 SQLite 备份里。macOS/Linux 目录 0700、文件 0600；当前用户权限的程序及备份可读取。更新前保存在钥匙串的 Key 不自动迁移，需重新填写一次。会话内容是本地明文，发送时将交给你选定的模型服务商。

自动任务免登录在本机运行，支持新建、编辑、暂停、删除、立即执行及本地历史。客户端关闭期间不执行，重开后到期任务合并补执行一次；沿用员工模型、目录与工具审批。详见[本地定时任务](requirements/local-scheduled-tasks.md)。技能广场免登录读取 GitHub 官方资源静态目录，进入页面及刷新时更新，失败显示错误并可刷新，不使用随包目录或本地缓存兜底。在原“添加”弹框中选择数字员工后，自动下载并校验完整技能包，安装成功才保存绑定；聊天自动加载真实指令及资源。首次安装需要联网，已安装包可在重启后离线复用（调用在线模型仍需网络）。官方技能默认来自 `https://zbwork.github.io/skills/`，数字员工来自 `https://zbwork.github.io/agents/`，技能包来自 skills 同一 Pages 站点的 packages/。可分别通过 `COMMUNITY_SKILLS_BASE_URL` 和 `COMMUNITY_AGENTS_BASE_URL` 指定同格式静态镜像；不再调用旧公共 API。列表刷新保留本地安装版本。

技能文件保存在应用支持目录的 `community-skills`，备份时应与数据库一并复制；每轮聊天生成临时资源快照，完成后清理。文件缺失或摘要不符时停止加载，在技能广场再次添加可重新下载恢复。包内脚本不会在安装时执行；运行仍受原本地工具权限控制，外部依赖与第三方账号需按技能要求配置。

损坏技能在原员工选择弹框显示“重新安装”。上传附件的原文件会复制到授权工作目录中的独立 attachments-* 子目录，供本地工具处理；源文件保留。删除员工会清理聊天、上传附件和员工私有运行数据；用户工作目录（包括导入副本、已生成文件）和其他员工的数据保留。单次消息含附件文字最多 150000 字符，历史只向模型发送最近的有界内容，数据库记录不裁剪。

## 可选服务端开发环境

以下内容用于开发服务端集成，默认本地桌面入口不会连接这些服务。

源码新增可选连接入口：点击头像菜单“连接服务器”，填写例如 `http://127.0.0.1:18080`，检测通过后使用服务器账号密码登录。登录页和头像菜单均可返回本地；菜单也提供“接入指南”。每次启动仍默认本地，只记住最近的服务器地址。HTTP 仅允许本机/私网 IP，公网使用 HTTPS。详见[连接契约](requirements/server-workspace.md)。

此入口复用现有服务端页面，不迁移本地员工、聊天或模型 Key。首次接入先使用部署的 Mock 助手验证；真实模型由服务端配置，IM、对象存储必须提供客户端可访问的地址。内置公开员工/技能目录与自建 Bus 是独立来源。

2026-11-12 已撤销本轮新增数据库脚本、后台页面及配套扩展，复用内网原有版本。历史联调仅描述撤销前的版本，不能证明当前源码完整可用。原社区基线存在共享服务辅助表和种子导出缺漏；完整技能装配、知识库等未做空库验证。公共技能仅浏览，当前服务器继续使用已有技能接口。详见[复用核对](architecture/community-schema-reuse.md)。连接成功只证明登录入口匹配，不代表全部能力可用。

# 安装与启动

## 本机已有旧部署时

先检查容器所属 Compose 项目与端口，保留旧项目和卷。可以在 deploy/community/.local/desktop 建立独立持久配置，使用项目名 zhiban-community-desktop；本机演示分配 Bus 38080、Admin API 38081、管理台 38082、WuKong WS 38083、对象存储 39000，均绑定 127.0.0.1。密钥、数据库口令和初始化账号放在该私有目录，不能提交。不要使用临时联调脚本的自动清理流程充当长期部署。

依次准备当前源码服务镜像、管理台、持久化空库与存储，执行迁移，再从 stdin 初始化管理员；用 Admin API 创建自己的租户后，桌面连接 Bus 地址并使用同一账号登录。重启使用本部署 compose 文件的 up -d；停止使用 stop 或 down（不加 -v）。默认 Mock 先验证收发，真实模型凭据由用户自行配置。

## 本地服务候选部署

可选服务端候选版本 v0.1.0-rc.1 尚未正式发布。以下服务流程在 macOS Docker 环境验证；公开源码树的后端、管理台构建已通过。macOS桌面社区版1.0.0的签名、公证和安装包状态见[发布记录](releases/community-macos-1.0.0.md)；按机器CPU选择arm64（M系列）或x64（Intel），最低macOS 13.5。Windows仍未验收。

需要 Docker Compose v2、OpenSSL、公开镜像和源码下载网络。进入 `deploy/community`，复制 `.env.example` 为 `.env`，为其中三个字段分别填写 `openssl rand -hex 24` 生成的不同随机值，然后执行 `./community-up.sh`。初次启动会构建镜像、生成 JWT 密钥、迁移空库和初始化对象存储。禁止指向现有商业数据库。

将含 Email、Name、Password 的单个 JSON 对象通过 stdin 输入 `./bootstrap.sh`；密码须为 12–1024 字节。不要把口令写入 shell 历史或提交到仓库。重复 bootstrap 拒绝覆盖管理员。

管理台访问 `http://127.0.0.1:18082`；Bus 为 `http://127.0.0.1:18080`，Admin API 为 `http://127.0.0.1:18081`。登录管理台创建租户后会生成默认 Mock 助手。WuKong WS 地址为 `ws://127.0.0.1:18083`，REST 不向宿主开放。所有端口默认只绑定本机。

`./community-down.sh` 停止服务并保留卷；`docker compose ps` 查看状态，`docker compose logs bus worker` 排查运行问题，分享日志前先去除个人信息。升级前备份 PostgreSQL、对象卷和 `.local/jwt.pem`；回退需要恢复配套数据库备份。不要使用 `down -v`，除非明确需要删除数据。

## macOS 源码构建前置

默认社区桌面使用本地入口，构建无需 Bus 参数；启动后通过侧栏“连接服务器”切换到可选服务端工作区。

先在仓库根执行 `cd apps/zhiban-local-bridge && go mod vendor`，按 go.mod/go.sum 准备桥接依赖，再返回仓库根。macOS 与 Windows 的桌面打包都使用 vendor；macOS 打包阶段刻意关闭网络且使用隔离模块缓存，因此单独执行 go build 成功不能代替此准备步骤。vendor 由构建者生成，已加入 Git 忽略规则，不提交到源码仓库。macOS 工程中的 CocoaPods 资源复制构建步骤需要保留并提交；它引用 pod install 生成的资源清单，不包含本机绝对路径。

桌面使用 Flutter、Xcode、CocoaPods 与原生 DingRTC SDK。DingRTC 二进制不随源码分发；进入 `apps/zhiban-app` 后先执行 `flutter pub get`，再执行 `./scripts/install_dingrtc_macos_sdk.sh`，脚本从阿里云官方地址下载 3.9.0 SDK 并执行 pod install，最后执行 `flutter build macos --debug` （无需 Bus 地址参数）。SDK 使用受阿里云原授权约束。跳过安装步骤会在 DingRtcBridge.swift 报找不到 DingRTC 模块。详细 SDK 说明位于 `apps/zhiban-app/macos/Frameworks/DingRTC/README.md`。

## 平台发布验收清单

服务端候选采用源码交付，验证环境是macOS与Docker Compose v2；桌面macOS 1.0.0已完成原生Release、签名与公证验证，发布状态见上述记录。Windows尚无验收结果。以下为平台发布的验收清单，不是启动上述本地服务的额外必填配置：

1. 支持的操作系统、架构及工具链版本。
2. 对应发布版本的下载或源码获取方式、校验方式和签名状态。
3. 配置样例位置、每个必填字段的用途与获取方式；仅使用部署者自己的配置。
4. 经过验证的一键启动、初始化、首次登录和示例对话步骤。
5. 桌面客户端构建/运行与连接本地服务的步骤。
6. 可选能力启用方式、缺失时行为、健康检查与常见问题。
7. 停止、升级、备份及回退步骤，说明哪些操作保留或删除数据。

不要使用未经过验证的临时命令或真实商业参数填充本页。问题反馈见[支持渠道](../SUPPORT.md)。


## 本地开发工具

打开桌面端即可使用，无需登录。点击左下角头像 → **本地开发工具**。Codex 和 Claude 分别提供 **API 设置**：

1. 先在「模型服务」配置并启用服务商、模型和自己的 API Key。Codex 要求 OpenAI Responses，Claude 要求 Anthropic Messages。
2. 在本地开发工具的「API 设置」中从原模型选择器选择配置并保存。地址、模型与 Key 自动取自模型服务，不提供手动填写；缺少配置时点击「管理模型服务」。
3. 按卡片提示安装工具、应用配置并检测连接。原有工具配置会沿用备份与恢复流程。

支持 HTTPS 地址；本机模型服务可使用 loopback HTTP 地址。社区版不访问系统钥匙串或 DPAPI，配置以明文保存。macOS/Linux 限制文件仅当前用户读写，Windows ACL 尚未验证。退出知办登录不会清除你的个人 Key。

数字员工也可免登录执行本地工作：创建或编辑时选择 DeepSeek Harness / Codex App Server；对话中选择已配置模型和工作目录。没有选择目录时使用文档目录下员工独立文件夹。读文件和新增文件按原 assist 策略执行，覆盖/删除/命令执行需批准；停止按钮撤销当轮执行。模型 Key 从「模型服务」读取，外部开发工具也只能从「模型服务」选择配置。Codex 要求服务商支持 Responses，Harness 支持 OpenAI compatible / Anthropic Messages；Google 原生协议保留文本分析。

运行数据、工具时间线和生成文件快照保存在应用支持目录 community-runtime 与 SQLite 中；输出也留在所选工作目录，不上传云盘。备份完整历史时同时保存 community_attachments、community_avatars、community-runtime 和 SQLite；Key 位于独立 community-credentials 目录，不在聊天数据库中。
