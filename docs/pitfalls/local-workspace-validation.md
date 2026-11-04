# 本地工作区验证注意事项

## 模型服务局部主题的中性色覆盖

ModelServicePageTheme 将 colorScheme.primary 覆盖为 onSurfaceVariant，不能用它表达品牌蓝链接。获取密钥入口沿用 UiSwitch 的 Theme.primaryColor；不修改整个页面主题。颜色回归必须包裹真实 ModelServicePageTheme，单独在 AppTheme 下检查不能复现此问题。

## 凭据存储与原生验证

社区版按用户选择使用本地私有明文文件，不使用钥匙串。Widget替身不能验证原生签名与文件权限，需独立验证目录0700、文件0600和重启读取。历史钥匙串调试过程见验证记录，不作为当前实现要求。

## Flutter widget 测试与 SQLite FFI

SQLite FFI 工作在真实异步隔离线程中，不能在 testWidgets 的虚拟时钟内直接等待数据库初始化。初始化/关闭放进 tester.runAsync，界面更新仍用 pump/pumpAndSettle；否则用例会停在启动等待，不能据此认定页面挂起。

## 桌面运行时打包缓存

macOS 构建发现 dependencies 缓存有 .complete，但 node_modules/typescript/bin/tsc 缺失。不能只凭标记认定编译依赖完备。打包脚本同时检查编译器文件，缺失时重装，并显式 npm ci --include=dev，防止构建者 npm 配置省略开发依赖。生产依赖仍单独 --omit=dev。

## 社区版已有模型测试

当前目录的 BeeBridge 地址为 api.airick.cn，旧测试仍断言 api.beeaicloud.com；商业托管 Key 测试期望 communityEdition=false 路径，而公开树固定为 true。验证报告需单独列出，不用降低本地安全隔离或改厂商地址来迁就商业测试。

macOS 原生编译随后发现本地 Go bridge 的 vendor 与 go.mod 不一致。按安装文档运行 go mod vendor 重建生成依赖；不修改锁定版本、不提交 vendor。

## 本地化不能改变产品 UI

用户要求免登录/本地数据不代表授权重做界面。不得用独立简化壳替代现有导航、卡片、聊天输入。先盘点可复用展示组件，隔离会话初始化，用本地数据驱动原组件；验收必须同时检查外观和无后端依赖。

## 原组件复用与空态约束

本地员工的模型应在对话输入框选择；恢复创建表单时不要因为数据表上有 model_id 就把会话控制字段塞回创建表单。原 ModelPickerEntry 含 ListView，showMenu 必须按原 LocalAgentControls 指定确定的宽度，避免 popup intrinsic measurement 访问 RenderViewport 报错。测试需实际打开菜单并选择。

数字员工列表即使复用 AgentCard，也不能自行换成固定两列或将列表宽度交给单张卡片决定。Column 默认不横向拉伸，SingleChildScrollView/Wrap 在只有一张卡片时可收缩并被水平居中；本地卡片区需撑满宽度且 Align.topLeft。卡宽复用原 desktopAgentCardWidth，12px 边距/间距保持原版。回归必须验证一项和多项的实际布局坐标。

只复用卡片不足以保留页面：头像 onTap、技能 Tab/筛选栏/我的技能列表也必须沿用原交互。桌面组件被本地共享页使用时，提取纯展示组件到 zhiban-client，桌面旧路径仅 export，避免两份样式。移入的组件依赖也须移入共享包 pubspec。

SingleChildScrollView 的子节点在滚动方向高度无界，Center 无法按视口垂直居中。列表空态通过 LayoutBuilder + ConstrainedBox(minHeight: viewportHeight) 填满可用区域，不能靠固定上边距补偿。

扩展原侧栏回归测试有两项旧断言不符当前公开树：desktop_sidebar_test 直接取 SidebarBillingSection，但 SidebarBottomDock 在 communityEdition 时本就隐藏计费；sidebar_profile_popover_test 期望自己的名片含「发消息」，当前 contact_profile_card 在三种操作回调均为空时本就不渲染操作区。这两处不属于本次组件修改，不更改业务行为来迎合旧断言。


## 复用完整组件，避免默认弹框回退

只复用员工卡片会漏掉来源 Tab、添加更多、详情后进入聊天的原交互；本地详情 Dialog、安装 SimpleDialog 和删除 AlertDialog 也会偏离原产品。应给原 Gallery/SkillDetailDialog/SkillInstallAgentDialog 注入本地数据与回调，并在 watch 远端 Provider 之前分支。带本地 file URI 的头像不可交给网络图组件；安装目标列表需使用文件分支。验证需实际打开详情、安装后使用并断言无网络，单看页面文案不能发现这些回退。

## macOS 每条消息重复弹出钥匙串授权

发送消息和配置页都会创建 ModelServiceStore；如果每次 getApiKey 都直接 read 系统钥匙串，用户仅允许一次或调试签名变化时会不断弹窗。采用仓库层按完整 scope/provider key 的进程内缓存，并合并并发读取；只缓存成功结果，保存更新、删除和写入失败失效。底层改为用户选定的私有明文文件；进程内缓存仍保留，不能修改钥匙串ACL。测试要清理静态内存缓存，并使用底层读取计数验证多个仓库实例复用，而非只检查返回字符串。

## composerEnabled 不是“请求忙碌”开关

ChatSessionView.composerEnabled=false 的既有语义是员工删除后的只读会话，会卸载 PromptInput 并显示“该数字员工已删除”。将它绑定 busy/文件解析会造成误提示、丢焦点及输入框闪烁。忙碌使用 ChatSessionState.isSending（原停止按钮），发送准备状态使用 sendReady。FutureBuilder 的消息 Future 要按数据修订复用，避免附件 setState 引发查询和 loading 闪烁；等待气泡携带持久化 streamStartedAt，不重置计时。

## 技能广场来源

Bus匿名公开接口是广场唯一来源，不再分发官网或旧manifest快照。原SkillIcon继续使用网络图标及默认图标，旧数据库asset地址在打开时清空。目录不等于执行包，安装仍须校验实际SKILL.md及完整资源，不能将简介当执行指令。
