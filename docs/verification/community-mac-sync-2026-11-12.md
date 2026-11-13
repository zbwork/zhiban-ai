> 后续修复进行中：用户要求在当前电脑同时调通客户端与后端。下文第一次验收中的服务器结果来自构建机，不是当前电脑的后端验收；接下来以本机独立部署复验替代，凭据不复制到构建机。

# Mac 构建机同步后本机验证（2026-11-12）

## 版本与配置

验证仓库为 zhiban-ai-community，合并版本 main / 2c3acec，包含构建机 baef57c 及本机 64fe13d。开始时目录实际在构建机原分支；发现后切回 main、重新构建并复验。main 比原分支靠前，原分支不包含本机截图、附件布局和隐藏 AI 提示等修复。

用户提供的蜂桥密钥仅写入本机客户端已有私有凭据文件，目录 0700、文件 0600；未写源码、文档、日志或服务器配置。蜂桥 /models 返回 200、17 个模型，客户端配置并选中 gpt-6.1-sol。原生自动化文本输入未可靠提交，配置使用客户端现有持久化格式，重启后模型选择器真实显示并可选。不能据此宣称原生键盘输入已经端到端验收。

## 已验证

| 范围 | 实际结果 |
| --- | --- |
| macOS main | Debug 构建通过，原生客户端启动、重开后本地员工/已安装技能/选中模型保留；未制作安装包 |
| 本地页面 | 原生检查员工列表/详情/进入聊天、头像、简介及技能标签；技能详情/选择员工/下载安装按钮由“添加”变“使用”，聊天技能栏可见；任务列表/空状态/创建表单/取消；最终原生聊天窗口可见用户自行发送的“你好”及真实模型回复；账号菜单及服务器检测表单可达 |
| 聊天显示 | main 原生会话头像正常，底部 AI 提示已隐藏；原分支仍有该提示，不能混用其结果 |
| 图片 | 公开目录 20 位员工、81 项技能；实际提供的 99 个图片地址逐个 GET，全为 200、image MIME、非空内容；未配置图片的项目使用原默认样式。原生卡片部分图片初次异步加载后显示 |
| 本机核心 | dart test：115 项通过 |
| IM SDK | CONNACK 拒绝及单连接/迟到回调：10 项通过 |
| 原运行时 | 使用 App 随包 Node/DSH/Codex 执行 24 项确定性回归通过 |
| 修复后运行时 | TypeScript 编译通过；26 项运行时回归通过，包含前置声明无副作用拒绝、显式声明后继续、只读/未启用声明要求保持原行为、shell 绕过前置检查仍被最终门禁拒绝、原文件/权限/取消/历史/附件检查 |
| 真实本地模型 | 使用正式 Controller 和实际运行组件：DSH 首轮 1591、历史工具后回答 ZB-MAIN-1112/8051、写入并读回 ZB-FILE-1112: 485 通过；Codex 原生桥接独立真实复验首轮、历史工具续答、文件声明/写入/读回及完成终态通过 |
| Go | community 全包、clientcatalog/clientfiles/clientrooms/clientpositions、room/directroom 定向 go test，通过；社区/客户端恢复路由 go vet 及六个社区入口 go build 通过 |
| 管理台 | 按锁文件安装本机依赖后 pnpm lint、pnpm build 通过；已有约 2.28 MB JS 大包警告 |
| 已有服务器 | 通过本机 SSH 转发复用构建机现有 desktop 服务，使用当前客户端服务与真实 SDK：登录/租户、员工/联系人/职位、技能绑定及会话栏、群聊/参与者、multipart 上传、签名预览下载逐字节一致、匿名/跨租户拒绝、知识库上传搜索、网盘上传下载删除、IM 连接及发送确认通过 |

真实模型测试使用独立临时员工与工作目录。确定性模型测试不替代真实模型结果；服务器验证没有部署本机新镜像，不据其成功声明任意服务端源码已全量验收。未创建数据库、执行迁移或修改表结构/权限种子。

## 本次发现与修改

DSH 曾成功写入并读回结果，但未调用 declare_deliverables，最终如实失败。工具说明“生成多文件前”与单文件也必需的门禁冲突；统一两引擎及工具说明后，Codex 仍可能遗漏。最终采用现有 Broker 参数校验模式，在 requireDeliveryDeclaration 已由宿主开启时，write_file/edit_file/publish_artifact 缺清单于审批和操作前返回结构化 local.delivery_declaration_required；模型显式补声明后才继续原流程。不自动声明、不重跑已执行工具，不放宽最终文件验证。Office/生图自动登记保持，shell 仍由终态门禁兜住。相关需求与踩坑同步更新。

## 未通过及限制

1. **服务器模型及自动任务未通过**：服务器现有模型端点请求实际返回 HTTP 403，任务 error=agent execution failed，聊天 chat.runtime_unavailable。其登录/IM/存储成功不能视为模型完成。用户本机新蜂桥 Key 有效，但未同步到服务器。
2. **Codex 历史续答仍有偶发失败，根因未确认**：一次真实 Controller 复验中 read_conversation_history 成功后，终态失败“本机执行未完整结束”；随后独立真实桥接复验成功。不能将本次单文件交付修复当作该历史问题已修复，也没有自动重试失败轮次。
3. **全量 Flutter 不通过**：桌面 173 通过、19 失败；共享客户端在其余测试完成时 1861 通过、3 跳过、71 失败，并在 chat_respond_notifier_test 的失败路径 widget 用例等待 10 分钟超时。后续 empty stream_id widget 用例仍等待时停止 runner；该文件其他 3 项单独执行通过。同步前 64fe13d 隔离快照复现同样 19/71 个断言失败和两个 widget 等待问题。初次实时桥接 debounce 用例一次失败，单独重跑 133 项全部通过，main 全量该项通过。逐项名称和诊断见[失败清单](community-mac-sync-2026-11-12-failures.json)。没有通过改回已删除提示或放宽断言“修复”旧测试。
4. **原生写操作覆盖不完整**：自动化文本输入未可靠写入 Flutter 控件；未完成原生登录、消息发送、文件选择/预览、任务创建/编辑/执行的完整鼠标键盘链路。已执行原生只读/选择操作、真实 Controller/运行时及真实服务测试，三者分别记录，不互相替代。
5. **启动与 SDK 警告**：一次 flutter run 启动停在加载态，退出后由原生重新打开正常，未确认原因；DingRTC/MoziWhiteboard 有重复 SessionDelegateWapper 类警告，未修改第三方二进制。
6. **后台、安装与平台未验收**：管理台未在本机逐页验证实际业务，历史缺表/权限/404 限制继续存在；未跑新空库、全部 Go 服务测试、正式签名发布、Windows、移动端或全部岗位技能任务。社区仓库没有 scripts/check-repo-hygiene.sh，未运行该脚本。

## 复验记录

本机日志保留于 /tmp/community-main-*、/tmp/community-verify-server-*、/tmp/community-images-verified-20261112.json。日志不作为公开文档附件；服务器 fixture 和凭据不提交。

关键命令：flutter build macos --debug --no-pub（社区版和公共目录 defines）；flutter test --no-pub；dart test；Node --test（community-runtime、community-attachments、codex-error-info）；Go 定向 test/vet 及六入口 build；pnpm lint/build；git diff --check。新增运行时修复后未重复无关全量 Flutter；其失败已与同步前版本对照。
