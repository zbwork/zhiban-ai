# 员工头像、技能图标及 Codex 续答修复交付（2026-11-09）

## 同批交付范围

服务端改动一次收齐到内部 `codex/f33-ai-office`：公开员工头像与公开技能图标同站读取、平台存储内网访问、逐资源可见性/当前绑定校验。没有新增数据库迁移，也不要求放开桶ACL。部署目标是本轮最终 f33 提交，不应部署前一版只含员工头像的中间工作区。

社区客户端同步适配两类相对图片地址，只使用公开目录 origin；官方会话头像刷新保留模型与聊天历史。新版 macOS 预览已经更新并通过 deep strict 签名校验，包内确认存在 Responses 修复。

## 历史工具中断的证据与修复

- 实际历史任务是 Codex（codex_app_server），不是 DSH。台账保留 HTTP200、历史工具成功和 `engine_error: other / parse / missing / stream disconnected`。
- 用随包真实 Codex 对本地模型响应构造终帧缺 response.id：旧包稳定失败，结果包含完全相同的安全错误特征。红测日志：`/tmp/community-codex-missing-id-before.log`。
- 只在单次响应流已有唯一明确 ID 时，给缺失 id 的 response.completed 继承该 ID。无先前 ID、出现冲突 ID、显式 null/不同 ID 都不猜测、不覆盖。不重新发模型请求、不重跑工具，不将 failed/incomplete 改成功。
- 同一故障用例在最终打包 Codex 上完整执行工具和回复，通过；否定边界、取消、拒绝及原工具参数/名称兼容继续通过。
- 历史那次没有原始响应帧，不能由相同特征反推它必定缺的是 id；本修复确认解决了可复现的同类兼容故障。

## 验证结果

| 验证 | 结果 |
|---|---|
| 完整本地工作区 Flutter 回归 | 53 项通过，0失败 |
| 内部运行时定向 Vitest + ZAP 合同 | 35 项通过，包含真实 Codex 工具往返、取消与失败 |
| 最终 App 包内 Node/DSH/Codex/附件/transport | 22 项通过，0失败/跳过；含 codex-missing-response-id 及唯一ID边界 |
| Go public、media、skill、agent、cmd/bus | 定向测试通过 |
| 真实 OSS 适配器本地 HTTP 集成 | 公网端点403仍能读取两类图片；HEAD/GET走固定内网端点、摘要/解码一致，公网端点零请求 |
| 非公开技能/员工和非法资源 | 归属、当前可见性、绑定文件、存储失败不泄密、类型/尺寸/摘要/重定向边界测试通过 |
| 静态检查/构建 | Go vet、Bus build、TypeScript typecheck、改动文件 ESLint、Dart scoped analyze、macOS Debug build及最终签名通过 |
| 两仓 diff check | 通过 |
| 仓库卫生 | 既有失败：zhiban.jks/apiclient_key.pem 跟踪路径，以及两份既有超过20MB的F05 PDF；未读取或修改这些文件 |

## 未完成的环境验证

线上仍是旧接口，真实图片恢复要在部署后确认。本地新 Bus 因测试库 DNS 不可解析未能连接真实存储配置；上述真实 OSS 适配器测试使用本地 HTTP 对象端点，不冒充真实生产库/桶联调。

最终预览启动后旧聊天与模型保留。尝试继续进行最新版真实上游续答时，桌面自动化无法建立输入焦点、坐标操作返回 noWindowsAvailable；重连仍未完成新消息发送，未计为新版本真实上游续答通过。已通过的确定性回归使用真实随包执行器、本地模型响应，工具实际执行。

上一轮全量报告中的9个技能包网络失败、空态文案及悬浮指针未充分验收不在本修复中冒充关闭；参见[完整复验](community-employees-2026-11-09.md)。未推送、未部署、未迁移。
