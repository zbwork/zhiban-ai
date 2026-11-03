# 社区版本地工具集成

- HTTP 400 不一定是固定 schema 错误。2026-11-03 实测 BeeBridge deepseek-flash 在首轮和工具成功后的续轮均可能返回 `bad_response_status_code` / `Request body format invalid`；同一请求体原样再发 HTTP 200。不能据错误分类认定 PDF 不可读，也不能把改工具后的偶然成功当作因果证据。社区代理仅对该目的端已确认拒绝做一次原样重试，不重放工具或成功流；仍失败则显示原错误。现有 ledger 不保留原始上游错误，历史截图的具体原文不可追溯。

- 工具文字备份不能只写裸名 read_file：真实联调显示模型会照抄裸名，DSH 只注册 mcp__local__read_file，仍报 unknown tool。备份目录必须给完整调用名；用最终产物实测 list_files→read_file 两次均成功，不能只凭提示词变更或 mock 判定修复。

- 最新失败轮 12 次工具调用中，10 次调用 tool/tool_2…tool_9 等未注册占位名，1 次根目录列表成功，1 次把 Markdown 文件作为目录。上游模型文字声称只见占位 schema，但不能据此认定发生在哪层；同服务商模型的单工具、完整工具及真实 DSH 列目录/读文件诊断均成功，未稳定重现占位定义。采用实际注册目录文字备份并去掉社区未注册的商业能力提示，不把未知名按序号强行映射。
- local.file_operation_failed 过去未进入错误字典，ENOTDIR 因此只显示原因未确认。受限静态文件子进程输出白名单错误码，宿主映射稳定提示；不回显 stderr，保留相同 OS 沙箱与审批边界。

- BeeBridge 的 DeepSeek 请求带完整工具时 HTTP 400 `invalid function call parameters`，普通聊天却 HTTP 200。逐个工具排查定位 office_create，再只修改工作表 name.pattern 的左方括号转义，完整工具即返回 200。JS 接受字符类中未转义的 `[` 不代表服务商解析器接受；不能误判 Key、禁用所有文件工具或去掉宿主校验。
- 社区直连返回 OpenAI/Anthropic error 对象，商业模型代理返回稳定 Bus message 错误码。只用 Bus 解析器会丢失 HTTP 状态和错误分类；在社区边界有界解析后转换为稳定 envelope，商业默认解析不变，不打印原始上游正文。
- 目录功能异常先比对员工 metadata、workspaces.json 和 ledger 工具事件。本次两处目录一致，失败轮没有工具调用：是模型请求失败挡住文件操作，不能据此重写目录或扩大 sandbox。

- Broker.listen 返回 origin（无末尾斜杠），Flutter Uri.path 可能为空；客户端校验应接受空路径或 /，但必须固定 http/127.0.0.1/显式端口，无 userinfo。HTTP 路径拼接显式带 /。
- macOS /var 与 /private/var 指向同一临时目录；ESM import.meta.url 是规范路径，入口判断先 realpath argv，避免脚本无报错直接退出。
- Responses 工具可能声明 namespace，mock 必须按请求 advertised tools 返回实际 namespace/name；写死 Chat Completions 的扁平工具名会让 Codex 收到无法执行的调用，不能仅凭回复文字认定执行成功。集成验收读取真实文件并检查 shell 结果。
- 原 Supervisor 要求文件交付声明；模型 mock 必须 declare_deliverables，不能删掉生产校验迁就测试。
- Artifact 原文件地址与历史快照不是同一个用途；消息保留独立已验证快照，避免用户改写工作文件后历史附件失效。
- helper 测试清理先等进程退出再删目录，避免 worker 清理写入与 rm 竞争（ENOTEMPTY）。
- 社区 Debug helper 为 ad-hoc（TeamIdentifier=not set），如果 Dart 仍执行商业 Developer ID requirement，会报“本地连接组件签名校验失败”。开发分支必须仍验证 strict 签名完整性和固定 identifier；Release 不放宽。完成 Flutter 构建后不要修改 App 内资产，否则外层资源 seal 失效；检查最终产物并重新签名调试包后再启动。
