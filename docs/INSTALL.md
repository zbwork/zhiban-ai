# 安装与启动

## 本地服务候选部署

候选版本 v0.1.0-rc.1 尚未正式发布。以下服务流程在 macOS Docker 环境验证；公开源码树的后端、管理台与 macOS Debug 构建已通过；Windows 与完整交互仍待验收，因此暂不提供签名安装包或正式下载地址。

需要 Docker Compose v2、OpenSSL、公开镜像和源码下载网络。进入 `deploy/community`，复制 `.env.example` 为 `.env`，为其中三个字段分别填写 `openssl rand -hex 24` 生成的不同随机值，然后执行 `./community-up.sh`。初次启动会构建镜像、生成 JWT 密钥、迁移空库和初始化对象存储。禁止指向现有商业数据库。

将含 Email、Name、Password 的单个 JSON 对象通过 stdin 输入 `./bootstrap.sh`；密码须为 12–1024 字节。不要把口令写入 shell 历史或提交到仓库。重复 bootstrap 拒绝覆盖管理员。

管理台访问 `http://127.0.0.1:18082`；Bus 为 `http://127.0.0.1:18080`，Admin API 为 `http://127.0.0.1:18081`。登录管理台创建租户后会生成默认 Mock 助手。WuKong WS 地址为 `ws://127.0.0.1:18083`，REST 不向宿主开放。所有端口默认只绑定本机。

`./community-down.sh` 停止服务并保留卷；`docker compose ps` 查看状态，`docker compose logs bus worker` 排查运行问题，分享日志前先去除个人信息。升级前备份 PostgreSQL、对象卷和 `.local/jwt.pem`；回退需要恢复配套数据库备份。不要使用 `down -v`，除非明确需要删除数据。

## macOS 源码构建前置

社区桌面只提供账号密码登录，账号由部署者 bootstrap 初始化；不使用短信、扫码或自助注册。构建时显式指定自己的 Bus 地址，例如本地 Debug 使用 `--dart-define=APP_ENV=dev --dart-define=API_BASE_URL_DEV=http://127.0.0.1:18080/api/agent-bus/v1`；Release 使用 `--dart-define=API_BASE_URL_PROD=<自己的Bus地址及/api/agent-bus/v1前缀>`。

先在仓库根执行 `cd apps/zhiban-local-bridge && go mod vendor`，按 go.mod/go.sum 准备桥接依赖，再返回仓库根。macOS 与 Windows 的桌面打包都使用 vendor；macOS 打包阶段刻意关闭网络且使用隔离模块缓存，因此单独执行 go build 成功不能代替此准备步骤。vendor 由构建者生成，不随候选源码导出。

桌面使用 Flutter、Xcode、CocoaPods 与原生 DingRTC SDK。DingRTC 二进制不随源码分发；进入 `apps/zhiban-app` 后先执行 `flutter pub get`，再执行 `./scripts/install_dingrtc_macos_sdk.sh`，脚本从阿里云官方地址下载 3.9.0 SDK 并执行 pod install，最后执行 `flutter build macos --debug` 并传入上文自己的 Bus 地址参数。SDK 使用受阿里云原授权约束。跳过安装步骤会在 DingRtcBridge.swift 报找不到 DingRTC 模块。详细 SDK 说明位于 `apps/zhiban-app/macos/Frameworks/DingRTC/README.md`。

## 平台发布验收清单

本候选采用源码交付；服务流程的验证环境是 macOS 与 Docker Compose v2。公开树 macOS Debug 源码构建已通过，尚无 Windows 验收结果或签名安装包。以下为后续平台发布的验收清单，不是启动上述本地服务的额外必填配置：

1. 支持的操作系统、架构及工具链版本。
2. 对应发布版本的下载或源码获取方式、校验方式和签名状态。
3. 配置样例位置、每个必填字段的用途与获取方式；仅使用部署者自己的配置。
4. 经过验证的一键启动、初始化、首次登录和示例对话步骤。
5. 桌面客户端构建/运行与连接本地服务的步骤。
6. 可选能力启用方式、缺失时行为、健康检查与常见问题。
7. 停止、升级、备份及回退步骤，说明哪些操作保留或删除数据。

不要使用未经过验证的临时命令或真实商业参数填充本页。问题反馈见[支持渠道](../SUPPORT.md)。
