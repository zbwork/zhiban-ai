# 社区版 README PC 实机截图（2026-11-10）

## 目标与拍摄方案

替换README开头两张旧营销/移动端拼图，使用当前社区PC客户端实际运行截图。主图展示数字员工处理演示数据后的分析结果、工具步骤和可预览文件，第二张展示官方员工和技能信息。保留实际UI，不能拼接虚构聊天、工具成功状态或未实现入口；数据明确标注演示，不展示真实密钥、用户私人资料或内部业务数据。

沿用README相对图片路径和明确alt文本（[GitHub Markdown图片](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#images)），采用用户提供的桌面参考取景，不保留手机覆盖图。实际模型执行与截图、文件校验结果完成后补录。

本轮同时按用户要求隐藏社区输入框底部固定提示，复用现有开关和共享聊天组件；不改模型、文件与审批逻辑。

## 实际运行结果

- 当前 main 源码构建 macOS Debug，预览路径为 apps/zhiban-app/build/community-preview/知办AI社区版.app；使用既有 .community.dev 工作区和已配置的 BeeBridge / gpt-6.1-sol，没有新增或修改密钥。发布的 v1.0.0 安装包未替换。
- 官方“经营分析师”处理合成 CSV，完整执行、生成并发布 Excel（185732 字节）与 PNG（193725 字节）；运行 add064c5-05df-4ef2-b067-9674f2605db0 的账本终态为 completed。6 行数据汇总费用 126.9 万元、工单 2941 单。PNG 侧栏真实加载，未拼接或伪造聊天。
- README 前两张替换为 community-desktop-analysis.jpg 和 community-desktop-employees.jpg，均为 PC 原始窗口截图；第二张展示当前公开目录、各岗位头像、简介及关联技能。保留其余 README 图片。
- 实机验证已有回复：交付在正文之后，Excel 文档卡片保留；PNG 显示真实缩略图，点击进入原右侧预览；输入框下固定免责声明已消失。无需数据库迁移。

## 回归与未通过项

- local_attachment_test 6 项通过，含持久化记录媒体分类、真实 PNG 解码及原文件约束。
- chat_assistant_message_view_test 定向 7 项通过，含正文/附件/来源标识顺序、文件打开回调和失败后已有交付；完整文件有 3 项既有等待梯文案断言失败，使用 HEAD 原实现复跑同样 3 项失败，未为本次修复改动等待状态。
- local_workspace_entry_test 包含底部提示缺席断言，前次运行通过。
- macOS Debug 构建、签名完整性检查通过。最终静态检查与文件校验另补。
- 期间 bf7be502-c87e-4877-89a4-e8af67fb64a2 确实失败，诊断为 parse/missing/stream disconnected；后续成功不能证明此间歇故障已修复。增加白名单 missing_fields 诊断，仍需下一次失败提供确切字段，不改变终态或自动重放。

最终验证：7 个修改 Dart 文件 analyze 无问题；附件 6 项及消息交付定向 7 项通过；新构建启动后历史 PNG 真实缩略图与侧栏均成功。新增解析诊断 2 项 Node 测试及 JS 语法检查通过。README 首图链接和两个 JPEG 文件（3024×1744）存在，工作簿 ZIP 结构及6张表检查通过。git diff --check 通过；本仓库没有 scripts/check-repo-hygiene.sh，未跑全仓测试和 Windows 构建。新诊断构建下两次真实续答（TESTOK、同样句号输入）均正常结束，间歇故障未再次复现，根因仍未确认，不能宣称已经修复。

最终补验：local_workspace_entry_test 在全部附件改动后重新运行通过；合计14项 Flutter 定向回归通过。打包运行时 stdio transport 回归1项通过（源代码目录无 ws 依赖，需按测试约定指向已构建随包 runtime，首次错误指向源目录曾报 ERR_MODULE_NOT_FOUND，修正环境后通过）。

## 用户最终选图

用户指定只保留其提供的一张社区版 PC 会话截图。README 开头最终使用 docs/images/community-desktop-chat.png，按原始 PNG 直接复制，不裁剪或重绘；替代此前两张 PC 图。前期两张拍摄图移出仓库，不作为 README 资源交付。校验 README 开头只有一个 img、本地路径存在，图片与用户提供文件 SHA-256 完全一致，尺寸2546×1616。此次仅调整文档和图片，无需重跑客户端构建。

## README 其余图片复核

用户要求继续检查并替换下方全部图片。旧7图均包含内部登录/积分/云端等社区版不符信息。本轮以当前 PC 实际程序重新拍摄开发工具、员工目录、技能广场、自动任务配置和文件预览；聊天复用用户指定实机图。社区版无云盘入口，原云盘展示替换为本地附件及交付文件预览说明。已安装的工具不为截图重新安装，重复的安装进度旧图移除。仅修正文档展示，不新增产品能力，不创建长期自动任务。

复核完成：7张旧图均已从 README 移除引用；5张替换为当前社区版 PC 实机新图，聊天一节复用用户选定的原图，旧安装进度重复图去掉。任务图仅填写草稿并取消，未创建定时任务；文件图为前次实际交付 Excel 的侧栏预览；工具图在自动检测完成后拍摄，未改 API 设置或安装软件。同步纠正相邻文案的旧本地149项技能说法、员工目录及云盘入口说明。

最终图片检查：
- docs/images/community-desktop-chat.png: 2546×1616, 677486 bytes
- docs/images/screenshots/community-dev-tools.jpg: 2546×1616, 292109 bytes
- docs/images/screenshots/community-employees.jpg: 2546×1616, 717776 bytes
- docs/images/screenshots/community-skills.jpg: 2546×1616, 636864 bytes
- docs/images/screenshots/community-task-editor.jpg: 2546×1616, 235305 bytes
- docs/images/screenshots/community-local-files.jpg: 2546×1616, 461233 bytes

验证：README 7处图片引用（6个唯一文件）全部存在，macOS sips 实际解码/导出校验通过；顶图与用户原图摘要一致；git diff --check 通过。仅文档/图片变更，未修改客户端代码，未重跑构建或单测；仓库无 scripts/check-repo-hygiene.sh。Python环境无Pillow，使用系统sips完成图片验证，无新增依赖。

### VS Code Markdown 图片补验

用户反馈开发工具图只显示 alt 文本。确认预览来自当前本机根 README，图片路径与文件均存在；不修改图片或 Markdown，执行 Markdown: Refresh Preview 后，开发工具、员工目录、技能广场、自动任务草稿和 Excel 侧栏图逐张实际显示。可确认故障在预览未重新加载资源；未采集网络日志，不断言底层具体缓存机制。此前只校验文件解码和链接，不能代替真实 Markdown 渲染验收。
