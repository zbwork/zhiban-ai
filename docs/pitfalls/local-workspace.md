
## 本地文档与富输入框

- 删除随包技能图标前，不仅要移除catalog资源引用，还需清理旧SQLite的asset图标地址，避免“我的技能”读取旧绑定时加载已删除资源。广场只用本次Bus响应ID集合投影，不能因聊天refresh重读数据库而重新显示旧列表；安装元数据和旧code-ID映射仍保留用于兼容。

- 附件接收与文本解析必须分开：file_selector 过滤器和 persist 的扩展名白名单都会阻止原文件交给工具，只改选择器不够。未知格式不能直接UTF-8解码；解析失败保留原件，消息明确需工具处理。原件必须按选择时摘要验证（仅长度/提取文字不能检测同大小二进制变化），旧历史允许缺省摘要。

- 复用 ChatSessionView 不会自动继承原 ChatPage 外层的原生文件拖放。跨入口恢复拖放应复用原 DesktopDrop，旧路径 export 共享实现；拖入路径必须进入与文件选择相同的有界读取和附件限制，不能直接信任 XFile 或走后端上传。
- 服务商默认聊天协议不等于工具可用协议的全集。多协议网关应有显式协议路径元数据；Claude 根 URL 与 OpenAI /v1 不同，不能只移除过滤或在所有自定义地址上拼猜路径。路由匿名 401 只证明存在，不代表 Key/每个模型可用。
- 用户要求完全不用钥匙串时，除了模型服务还必须检查 Bridge BYOK；它有独立凭据后端。禁止为“自动迁移”再读取旧系统项导致重新弹授权。持久化改为明文必须同步 ADR、安装说明与设置提示，保留地址绑定和文件最小权限；固定密钥加密不能替代系统凭据库保护。
- 发送一次定位与回复被动跟随必须独立处理，不能关闭自动跟随后遗漏新问题的顶部定位。为既有消息 anchor 增加 localId 别名时须追加到原 ID 之后，避免改变用于行 key 的首项，破坏原列表身份和历史定位。
- 禁止回复自动滚底时，不能只停流式 ticker：新增消息 smartScroll、输入框高度测量和 didChangeMetrics 都可能回底。应透传同一自动滚动策略覆盖被动路径，保留初次定位与用户显式回底，回归同时检查正文增长和消息数增长。
- 历史导航判断单文本块必须检查 draftBlocks 结构，不能拿已 trim 的 textWithoutAttachmentTokens 与原文相等判断，否则带首尾空格/换行的历史恢复一次后无法继续。键盘 widget 测试通过 enterText 或控制器更新后须 pump 让 EditableText/富文本展示同步，再发送下一次物理按键；避免把未刷新的编辑状态误判为历史导航丢草稿。

- 缓存查询 Future 不能保证流式内存和 SQLite 行一致。回复结束先删除 liveText/timelines 再 refresh，FutureBuilder waiting 仍持有旧 pending 行，正文会退回空白。按员工保留完整展示快照直到新查询 done，时间线复制为不可变列表。逐帧测试关闭保护后正文为空，开启后正文与消息列表 State 保持。员工切换须给异步视图独立 key，防止旧员工快照串入。

RichPromptController 已负责附件卡片，不应再写一套上传组件。ChatSessionView 默认同步清空输入；本地解析/模型配置校验是异步流程，必须通过 sendGuard 保留草稿，在消息持久化成功后清空，避免 Key 缺失丢附件。桌面预览必须位于 AttachmentPreviewHost 的子 Builder 内，回调使用 Scope 下的 context，否则会回退为弹框。

ZIP 中声明的解压大小不可当作实际上限，archive 的 verify 参数也不能代替显式 CRC 检查。读取所需 OOXML 部件时使用有上限的解压输出 Sink，并核对实际长度与 CRC，不落地解包。Flutter widget 测试中的本地文件 IO/isolate 必须在 tester.runAsync 中启动，单独等待不能推动 fakeAsync 内启动的 IO。

## Review 边界回归（2026-11-03）

凭据目的端绑定必须覆盖“已有 Bridge 配置”和“从模型配置带入”两条路径；只在 selectedModel 非空时监听地址变化会漏掉已有配置。清空/销毁密钥控制器前先移除监听，避免销毁时 setState。发送限制须同时检查 UI、helper schema、LocalTask 校验与父进程 JSON 行长度，后者还应容纳 JSON 对控制字符的再次转义。安装健康与员工绑定是独立状态，恢复入口不能只靠绑定标志显示“使用”。附件提取文本不等于把原文件交给执行器；须用摘要校验和工作目录相对路径验证实际可读取。

Future.whenComplete 的清理回调必须返回 void。直接返回 pending.remove(id) 会返回当前 Future，形成自等待，导致文件与数据库已安装但“添加”一直等待；回归须等待完整安装 Future 并验证并发只下载一次。macOS 的 /var、/tmp 含系统链接；传给运行时的私有技能快照目录须先 resolveSymbolicLinks，再执行规范路径和员工目录边界校验，不能为兼容临时目录而放宽边界。
