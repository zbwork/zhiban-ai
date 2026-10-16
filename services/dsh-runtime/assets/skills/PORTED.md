# 平台内置技能（从 OpenClaw 平移）

来源：`deploy/openclaw-deploy/builtin-skills`（a6c2a939 2026-07-15）
生成：`scripts/port-openclaw-skills.sh`（请勿手改本目录，改脚本重跑）

已平移：aigc-ppt baoyu-diagram baoyu-format-markdown baoyu-url-to-markdown chart-visualization code-daily-summary data-analysis markitdown ppt-generation yt-dlp zhiban-kb-search zhiban-output-style
未平移：aigc-skill-creator wecom-bot-setup zhiban-fix-skill-deps（OpenClaw 运行时专属语义，见脚本头注释）

dsh 侧约定：产物写 `outbox/`（本轮结束自动作为附件回传）；入站附件在 `.attachments/`；工具 cwd = 会话工作区；
图片生成 = `mcp__zhiban__image_generate`，知识库 = `mcp__zhiban__kb_search`。bun 系技能的 node_modules 在镜像构建期 `bun install`。
