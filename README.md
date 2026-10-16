# 知办AI · Zhiban AI

![知办AI：团队、数字员工与工作空间](docs/images/zhiban-community-cover.png)

**让数字员工加入你的团队，在自己的环境里开展 AI 协作。**

知办AI 是面向团队的 AI 协作平台。它把对话、数字员工、技能与文件放进同一个工作空间，并提供服务端、管理台和 Agent 接入能力。社区版支持自行部署，你可以从本地 Mock 助手开始，再按需接入自己的模型与运行时。

[快速开始](docs/INSTALL.md) · [反馈问题](https://github.com/zbwork/zhiban-ai/issues) · [参与贡献](CONTRIBUTING.md) · [官网](https://www.zbwork.cn/)

> 当前为 **v0.1.0-rc.1 源码候选**。macOS Debug、社区后端、管理台及 Docker 镜像已取得构建证据；尚无正式发布的签名安装包。封面为 AI 生成的概念插画，不是产品截图。

## 为什么做知办AI

和 AI 聊天只是开始。团队还需要知道：谁可以使用哪个数字员工、对话与文件放在哪里，以及如何把自己的 Agent 接进来。知办AI 将这些协作要素放在一起，帮助开发者和团队搭建自己的 AI 工作空间。

- **以数字员工组织协作**：在管理台配置员工，进入客户端开始对话。
- **在自己的环境里部署**：社区服务使用自己的数据库、对象存储和模型配置。
- **从演示走向集成**：先用默认 Mock 助手跑通链路，再对接自己的模型和 Agent；Mock 不会调用真实大模型。
- **客户端与管理职责分开**：桌面面向日常使用，管理台负责租户、员工与组织管理。

## 社区版能做什么

| 模块 | 当前能力与范围 |
|---|---|
| 桌面客户端 | macOS / Windows 桌面源码；社区版使用账号密码登录，macOS Debug 构建已验证 |
| 对话与消息 | 会话列表、消息历史、Mock 对话；WuKong 服务端消息链路已验证，完整桌面 SDK 流程仍待验收 |
| 数字员工 | 社区管理台创建、编辑、发布和删除员工；新租户提供默认 Mock 助手 |
| 租户与组织 | 租户创建和切换、成员与部门管理；操作受服务端权限约束 |
| 文件与云盘 | 对象存储、文件上传下载与云盘基础接口；聊天文件导入等扩展流程仍待验收 |
| 技能、任务与知识库 | 提供已有目录/列表读取；不代表技能安装、任务执行和知识库检索已完整交付 |
| Agent 集成 | 提供社区后端与 DSH 运行时源码，供开发者按协议扩展；默认 Compose 使用 Mock |

移动端、商业支付及商业运营能力不在本次社区交付范围。完整浏览器交互、真实模型、Windows 目标机与签名安装包仍需进一步验收。

## 从本地开始

需要 Docker Compose v2、OpenSSL，以及下载公开依赖和镜像的网络。

1. 进入 `deploy/community`，将 `.env.example` 复制为 `.env`。
2. 按[安装说明](docs/INSTALL.md)为数据库、对象存储与消息回调配置不同的随机口令。
3. 执行 `./community-up.sh`，构建并启动社区服务。
4. 按安装说明通过标准输入执行 `./bootstrap.sh`，创建初始管理员。
5. 打开管理台，登录并创建租户，使用默认 Mock 助手开始验证。

| 本地入口 | 地址 |
|---|---|
| 社区管理台 | http://127.0.0.1:18082 |
| 客户端 Bus API | http://127.0.0.1:18080 |
| 管理 API | http://127.0.0.1:18081 |
| WuKong WebSocket | ws://127.0.0.1:18083 |

端口默认只绑定本机。桌面源码构建、SDK 准备、Bus 地址配置、停止服务和备份操作，请遵循完整的[安装与启动指南](docs/INSTALL.md)。社区账号由部署者初始化，不提供短信、扫码或自助注册。

## 项目结构

```text
apps/
  zhiban-app/          桌面客户端（Flutter）
  agent-bus-admin/     社区管理台（React / TypeScript）
  zhiban-local-bridge/ 本地桥接（Go）
packages/             客户端共享业务、UI 与契约
services/
  agent-bus/          社区 API、worker 与数据库迁移（Go）
  dsh-runtime/        Agent 运行时适配（TypeScript）
deploy/community/    Docker Compose 与初始化工具
third_party/         随源码保留的第三方组件
```

本地桥接和 DSH 源码随候选提供，不表示其所有产品入口已在默认社区部署中启用。

## 适合谁

- 想搭建内部 AI 协作环境、愿意自行部署和维护的团队。
- 希望对接自有 Agent、模型或业务系统的开发者。
- 希望研究桌面、管理台、服务端协作实现的开源使用者。

当前源码候选适合开发和评估。准备生产使用时，请结合自己的部署环境完成安全、备份和业务验收。

## 参与社区

欢迎通过 [GitHub Issues](https://github.com/zbwork/zhiban-ai/issues)反馈问题和提出建议。提交问题时请附系统版本、复现步骤和脱敏后的日志。代码及文档贡献政策见[贡献指南](CONTRIBUTING.md)。

- [支持渠道](SUPPORT.md) · [安全漏洞私密报告](SECURITY.md)
- [行为规范](CODE_OF_CONDUCT.md) · [维护流程](GOVERNANCE.md)
- [更新记录](CHANGELOG.md) · [第三方声明](THIRD_PARTY_NOTICES.md)

## 许可与商业授权

知办AI社区版采用标准 [GNU Affero General Public License 第 3 版（AGPL-3.0）](LICENSE)，允许遵守适用条款的商业使用。第三方组件保留各自许可与归属。

如需获得 AGPL 义务豁免，可另行协商商业授权，具体范围以双方协议为准。请访问[知办AI 官网](https://www.zbwork.cn/)的“联系销售”入口。

版权署名：知办团队。项目名称与标识不代表对第三方服务或衍生产品的背书。
