# 官方资源 GitHub 迁移及客户端验收（2026-11-13）

## 当前方案

源码分别在 [zbwork/skills](https://github.com/zbwork/skills) 和 [zbwork/agents](https://github.com/zbwork/agents)。skills 按分类 README → 每技能目录 SKILL.md 与附属资源组织；agents 按角色目录 AGENT.md 组织，prompt_file 指向唯一内容源。保留原 UUID/code/version、技能依赖、头像图标与第三方许可。

客户端匿名读取两个 GitHub Pages 站点：skills 的 catalog/v1/skills.json、assets/skills/、packages/，agents 的 catalog/v1/employees.json、assets/agents/。不创建 Release / 标签，不访问原公共 API，不发送 Bus / GitHub token。部署前从 AGENT.md 生成展开 system_prompt 的目录，技能包保留原双层 manifest 和安全解析。

## 远端确认

用户已推送，Codex 未执行远端 Git 写入。

| 仓库 | main | Pages 部署 |
| --- | --- | --- |
| skills | 7194f8d | [43383724853 成功](https://github.com/zbwork/skills/actions/runs/43383724853) |
| agents | 34244d6 | [43383728216 成功](https://github.com/zbwork/agents/actions/runs/43383728216) |

两个 Validate 工作流也通过。在线 skills 目录已确认 81 个 bundle_url 全部为 packages/ 相对路径，替代此前 Release 链接。旧误发布的 Release 保留为草稿，旧发布工作流不启用、不触发；未删除或改写远端 tag。

## 客户端改动

- CommunityResources 统一两站点配置及旧官方头像/图标摘要改址，可用编译变量指定同格式静态镜像。
- CommunityEmployeeCatalog / CommunitySkillCatalog 使用独立匿名 Dio；缓存按来源隔离，旧服务器无回退。
- 下载只接受配置站点 packages/，拒绝 Release、站外地址和越出包目录的重定向；沿用原安装器摘要、大小、路径、压缩包及文件验证。
- UiNetworkImage 公共资源强制匿名，包括显式传入 Authorization 的情况；私有图片与权限保留。员工列表、详情和历史会话共用此出口。
- UI 验收等待真实 CachedNetworkImageProvider 的解码图像，不能把默认机器人 AssetImage 当加载成功；独立 bundle，未登录或重启用户窗口。

## 本地完整验证

- 两仓 build.py 构建与完整性校验通过：81 技能 + 79 图标、20 员工 + 20 头像；静态站点分别约 29MiB / 31MiB。
- Flutter 定向回归 + 双静态根目录联调共 24 项通过，公共图片剥离显式凭据 / 历史改址 / 保留私有鉴权另 3 项通过；20 员工依赖、99 图片 SHA-256 和真实图像解码、81 包安全解析全部通过。日志 /tmp/github-pages-client-tests.log。
- 定向 dart analyze 与 UI 验收入口 analyze 通过；无根 scripts/check-repo-hygiene.sh，未运行该脚本。
- macOS debug 独立原生 UI 通过：浏览员工、查看真实人像；点击个人任务规划专家 → 去聊天，实际下载 3 个技能并绑定，进入原本地对话；打开技能广场显示真实图标。截图已查看：/tmp/github-split-resources-ui/{employees,employee-installed,skills}.png，checks.json=passed。
- 独立预览 bundle cn.qkfintech.zhiban.community.pagesclient.verification，PID 38433 已停止。本地静态 HTTP 服务 PID 36982 已停止，后续线上验收不能借用本地服务。

## 真实 GitHub 在线验证

- 真实线上客户端目录类 + 下载类全量验证通过：20 员工技能依赖、99 张图的摘要和解码、81 个技能包安全解析。182 次请求全部 HTTPS、匿名 GET，主机仅 zbwork.github.io，全部 HTTP 200；其中 81 次为 /skills/packages/。日志 /tmp/github-pages-online-client-tests.log，审计 /tmp/github-live-resource-audit.json（仅 host/path/status，无凭据）。
- 独立 macOS 原生客户端使用默认 GitHub URL、无本地资源服务：首次员工列表、详情页、下载安装所需 3 个技能并打开会话、技能广场、返回员工列表全部通过，checks.json=passed。已实际查看 /tmp/github-online-resources-ui/{employees,employee-detail,employee-installed,skills,employees-reopened}.png；首次列表和详情是真实人像，非机器人占位，技能为真实图标。
- 最终 bundle cn.qkfintech.zhiban.community.pagesverified.verification，PID 43844；保留窗口供查看，未登录任何账号。正常 main 的 macOS debug 构建也通过，磁盘入口已恢复（/tmp/github-pages-normal-build.log）；未执行正式签名、打包或 Release。
- 图片验收第一次判断网络 Image 的任意 RawImage 后代仍误判，实际是 frameBuilder 把 AssetImage 占位嵌入其下。最终通过 RawImage 最近 Image 祖先身份确认网络像素归属，重新完整运行并查看截图。生产图片逻辑没有为验收放宽或伪造。
- 一次独立窗口后台等待绘制帧停住，调试 RPC 的实时树仍在目录等待；将该独立窗口置前后继续完成。本轮不把等待当成资源服务器失败，也不触碰用户账号；LiveWidgetController 的 pump 等待真实 endOfFrame，窗口可见性须作为 UI 验收环境条件。

## 已知边界及未验收

- 原人力资源专家的独立提示词为空，原样保留并标注 not_configured，未生成虚假人设；不表示 20 岗位各项业务能力均已验收。
- 本轮验证公共资源分发、安装与 UI；不调用模型或发送 AI 消息，不登录服务器账号，不视为模型、服务器定时任务或人际聊天验收。
- 未跑全量 Flutter、Windows、移动端、签名安装包和全部岗位业务任务；既有第三方 DingRTC / MoziWhiteboard 重复类警告未修改二进制。

## 历史纠正

早期误用了 Release，用户纠正后已停止并撤回草稿，改源码优先。源码布局两个提交 2cec8bd / 421aea4 经用户推送并校验成功；本轮用户明确继续客户端使用，新增仅 Pages 部署。此前一次线上截图只判断 RawImage，可能把机器人占位当真实头像，本轮更正验收条件并重新验证，不复用该次 UI 结论。原合并资源草案只在 /tmp 保留，正式资源仅两个仓库。
