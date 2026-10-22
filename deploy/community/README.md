# 社区本地部署（实施中）

当前提供 PostgreSQL、Redis、MinIO、迁移、Bus/Admin API、审计和文件维护 worker。已加入独立社区管理台；已接入 WuKong agent-direct 服务端闭环，桌面 SDK 验收待完成；不代表完整社区版发布验收通过。

需要 Docker Compose v2、OpenSSL 和可下载公开镜像的网络。服务镜像从本仓库源码构建，不读取私有配置仓库。

1. 复制 `.env.example` 为 `.env`，分别填入 `openssl rand -hex 24` 生成的三个不同值（POSTGRES_PASSWORD、OBJECT_PASSWORD、WUKONG_WEBHOOK_SECRET）。
2. 执行 `./community-up.sh`，它创建本地 Ed25519 JWT 密钥并保留数据库卷。
3. 将含 Email、Name、Password 的单个 JSON 对象通过 stdin 传给 `./bootstrap.sh`。密码至少 12 字节；不要把真实密码写入 shell 命令历史。重复初始化会拒绝覆盖已有管理员。
4. Bus 地址 `http://127.0.0.1:18080`，Admin API 地址 `http://127.0.0.1:18081`。两者使用各自 API 前缀。
5. `./community-down.sh` 停止服务并保留数据。不要使用 `down -v`，除非明确要删除数据。

对象存储内部写地址使用 host.docker.internal:19000（容器 extra_hosts 注入 host-gateway），签名下载地址为 127.0.0.1:19000。已验证本机代理上传和签名下载字节一致；跨机器访问需要部署者配置可达的读写地址。社区管理台地址为 http://127.0.0.1:18082；WuKong 客户端 WS 为 ws://127.0.0.1:18083；REST 仅容器内可达。真实模型、桌面 SDK 和完整管理 UI 验收仍待完成。

升级前备份 PostgreSQL、对象卷及 JWT 文件；迁移有校验和保护。不要把社区迁移应用到已有商业数据库。回退需要配套数据库备份，不能只切换镜像。

知识库文档解析：部署镜像包含 Poppler、antiword、LibreOffice 和 Tesseract 中英文 OCR；支持文本/Markdown/CSV/JSON、doc/docx/xls/xlsx/ppt/pptx、图片及 PDF 逐页文字提取/OCR。PDF 最多 20 页，超限、密码保护或无法识别内容明确拒绝。单文件默认 50 MiB，提取文本上限 16 MiB；单工具一般 30 秒，旧 Office 转换 60 秒，整条提取链 120 秒；Office ZIP 展开上限 32 MiB。原件保存在 MinIO，下载前检查当前租户与知识库权限。

知识库原件清理：worker 每分钟轮询已删除文档/知识库，每轮最多 45 秒；对象删除失败保留持久化键并自动重试。部署时需要同时升级 Bus 和 worker。该任务只清理租户知识库对象，不处理平台或其他路径。

应用 H5/OAuth 装配：通过 COMMUNITY_APP_ISSUER 配置自己的 HTTPS issuer，并向 Bus 注入 AGBUS_SECRETBOX_KEY（32 随机字节的 Base64，持久保存且不能随重启变更）；也可在 service.yaml 设置 appissuer。未配置 issuer 时不注册应用启动及换码路由。签名密钥加密保存在 PostgreSQL，Discovery/JWKS 使用该 issuer。本机 macOS 密码登录、应用列表及 H5 免登已验收；外部域名部署须独立验收。
