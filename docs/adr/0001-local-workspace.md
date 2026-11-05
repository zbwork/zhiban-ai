# ADR-0001：社区版桌面使用独立本地工作区

状态：采用。

现有会话、身份、任务和 dsh-runtime 入口依赖 Bus 注册。社区版要求不登录、不部署后端，不能通过跳过认证后继续启动 SessionLayout 实现。

在共享 zhiban-client 包增加本地工作区、SQLite 仓库和模型直连；桌面 communityEdition 入口使用免会话路由，复用原 MainLayout/DesktopSidebar 及消息、输入、卡片、个人设置展示组件；本地数据投影到现有展示模型，复用唯一模型配置仓库。原有服务端模式入口保留。模型元数据用现有 SharedPreferences 仓库，Key 按用户选择使用本地私有明文文件（目录0700/文件0600），本地业务数据使用独立 SQLite 文件。

不伪造 JWT、不调用 admin API、不让 Flutter 直接访问服务端数据库，不复制商业会话 Provider。未登录自动任务按本地定时任务需求使用 SQLite 与客户端调度。本地工具通过ADR-0002的独立helper接入，技能广场只使用Bus公开目录，安装包与员工绑定保存在本地。
