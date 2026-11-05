# 本地定时任务实现注意事项

- 五字段 cron 无年份，不能用原服务端 fromJob 的未来年份推算回显本地单次任务；必须保存完整 once_at。
- 在外部执行前持久化认领和下一次时间，防止重启重复副作用；中断记录不自动重试。完全访问只在会话内，不可写入任务。
- Flutter widget test 的 SQLite FFI 在真实 worker 中运行，pumpAndSettle 不会驱动数据库 IO；交替 runAsync/pump 等待真实链路，不通过反复 fake 时间推进制造锁超时。
- 原任务卡片右侧固定 100px，26px 时间与成功图标组合会溢出；原组件通过 Flexible/FittedBox 保留图标并缩放时间。
- 局部 Service 覆盖须同步声明 Notifier dependencies；任务页离开后异步刷新须检查 ref.mounted。刷新不能清掉当前筛选任务的历史快照。

- Cron 通配步进同样有匹配约束，不能把 startsWith('*') 等同于该字段永远成立；有通配字段时检查 dom && dow，两字段都显式受限才用 dom || dow。
- 定时任务私有 _employees 不会拦住普通聊天；必须在任何认领 IO 前取得聊天共用令牌，并将令牌交给执行链，直到终态回写后释放。不要依靠忙状态预检查或失败后重试补救竞态。
