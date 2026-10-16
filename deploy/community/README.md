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
