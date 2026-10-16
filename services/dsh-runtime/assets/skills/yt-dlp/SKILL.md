---
name: yt-dlp
description: Download video / audio from YouTube / Bilibili (B站) / X (Twitter) / TikTok (抖音/Douyin) / Vimeo / Weibo and 1700+ other sites using `yt-dlp`. Local processing, no API key required. 中文：下视频 / 下载视频 / 下 B 站视频 / 下抖音视频 / 下 YouTube / 下 X 推文视频 / 下 TikTok / 提取视频音频 / 把这个视频存下来 / 转成 mp3 / 拿到原片. ALWAYS use this skill when user provides a video URL and asks "下载" / "存下来" / "提取音频" / "转 mp3" / "save locally" / "rip this video". Output is saved under `outbox/`; reply with `[文件名](<outbox/...>)` (CommonMark angle-bracket URL — handles spaces / parens / unicode in filenames) — the platform attaches every new file under `outbox/` to your reply automatically.
metadata:
  openclaw:
    homepage: https://github.com/yt-dlp/yt-dlp
    license: Unlicense
    requires:
      bins:
        - yt-dlp
        - ffmpeg
---

# yt-dlp

通用视频/音频下载 CLI（YouTube / Bilibili / X / TikTok / Vimeo / 1700+ 站点）。

## 何时使用

用户给出视频 URL 并要求"下载"、"保存"、"提取音频"、"获取字幕"：

- "下载这个 YouTube 视频 https://..."
- "把 B 站这个视频存下来"
- "提取这条视频的 mp3"
- "下载字幕"

## 不抢的场景

- "看一下这个视频说了啥"——优先 `summarize`（直接出摘要，不下文件）。
- "把视频 URL 转成 markdown"——优先 `baoyu-url-to-markdown`（YouTube adapter 抓 transcript + metadata）。
- "提取视频里的画面截图"——优先 `video-frames`（OpenClaw bundled，专做抽帧）。

## 用法

```bash
# 默认：下载最佳画质 mp4 到当前目录
yt-dlp "https://www.youtube.com/watch?v=VIDEO_ID"

# 指定画质（先看可用清单）
yt-dlp -F "<URL>"
yt-dlp -f "bestvideo[height<=720]+bestaudio/best" "<URL>"

# 仅音频转 mp3
yt-dlp -x --audio-format mp3 "<URL>"

# 下载字幕（不要视频）
yt-dlp --write-subs --write-auto-subs --skip-download "<URL>"

# 输出文件名模板（推荐）
yt-dlp -o "%(title)s.%(ext)s" "<URL>"
```

## 输出处理

- 默认下载到当前 cwd；agent 调用前先 `cd` 到 workspace 内的合适子目录（如 `downloads/`）。
- 用 `--print after_move:filepath` 可拿到最终文件路径，方便后续传给其他 skill（如 `markitdown` / `summarize`）。
- 下载完后告诉用户文件大小 + 时长，确认是否继续后续操作。

## 安装与依赖

镜像已 `pip install yt-dlp` + 系统 `ffmpeg`。要升级到最新（YouTube 经常改协议）：

```bash
pip install --upgrade yt-dlp
```

## 故障排查

| 现象 | 解决 |
| --- | --- |
| `Sign in to confirm you're not a bot` (YouTube) | 加 `--cookies-from-browser firefox` 或用 `--cookies cookies.txt` |
| B 站 403 / 高清要会员 | 普通画质可下；高清需 `--cookies` |
| 下载特别慢 | 加 `-N 4`（并发分片）；或换 IP |
| 直播流 | 加 `--live-from-start`，或 `--wait-for-video 60` |
