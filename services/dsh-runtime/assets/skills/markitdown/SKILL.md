---
name: markitdown
description: Convert PDF / Word (.docx, .doc) / Excel (.xlsx/.xls/.csv) / PowerPoint (.pptx, .ppt) / HTML / 图片 (OCR) / 音频 (语音转写) / EPUB / ZIP / YouTube URL into clean markdown using Microsoft's `markitdown` CLI (legacy .doc/.xls/.ppt 自动经 antiword/catdoc/xls2csv 预转). Local processing, no API key required. 中文：把 PDF 转 markdown / 把 Word 转文字 / 提取 Excel 内容 / 解析 PPT / OCR 这张图 / 转写这段音频 / 看下这个文件写的啥 / 读一下这份 PDF / 把这个文档变成文字. ALWAYS use this skill when the user uploads any of these formats and asks "提取文字" / "转 markdown" / "读一下" / "看下里面写啥" / "convert to text" / "extract content". If the converted markdown is saved to a file under `outbox/`, the platform attaches every new file under `outbox/` to your reply automatically.
metadata:
  openclaw:
    homepage: https://github.com/microsoft/markitdown
    license: MIT
    requires:
      bins:
        - markitdown
        - antiword
        - catdoc
---

# markitdown

Microsoft 的 `markitdown` CLI 通用文档转 markdown。

## 何时使用

用户上传/给出文件路径，需要"读懂内容"或"转成可处理文本"时：

- PDF / Word (.docx) / Excel (.xlsx, .csv) / PowerPoint (.pptx)
- **legacy MS Office**：`.doc` / `.xls` / `.ppt`（OLE2 二进制，1997-2003 格式）—— `markitdown` 自己不读，必须先经 `antiword` / `xls2csv` / `catppt` 预转纯文本，**不要直接 `cat` / `strings`，那只能看到乱码**。详见下方「legacy Office 处理」。
- HTML 网页（本地或 URL）
- 图片（带 OCR，需 Tesseract，可选）
- 音频（带转写，可选 OpenAI Whisper）
- EPUB / ZIP（内含上述格式）
- YouTube URL（抓字幕）

## 不抢的场景

- 用户只问"看一下这个文件"——优先 `summarize`（拿摘要而非全文）。
- 用户给的是网页 URL 且想要"结构化抓取"——优先 `baoyu-url-to-markdown`（带 X / YouTube / HN adapter，效果更好）。
- 用户要"分析"Excel/CSV 数据（透视、统计、SQL）——优先 `data-analysis`。

## 用法

```bash
# 基础：任意支持格式 → markdown
markitdown <input-path-or-url> > out.md

# 指定输出路径（推荐）
markitdown <input> -o out.md

# 多文件批量
for f in *.pdf *.docx; do markitdown "$f" > "${f%.*}.md"; done
```

## legacy Office 处理（.doc / .xls / .ppt）

Microsoft 的 `markitdown` 只支持现代 Office (`.docx` / `.xlsx` / `.pptx`)，**不读 1997-2003 OLE2 二进制**。识别方法：`file <input>` 输出含 `Composite Document File V2` 即为 legacy。镜像已烤入 `antiword` / `catdoc`（`/usr/bin/antiword` 是个 wrapper 默认带 `-m UTF-8.txt`，中文 .doc 直接 `antiword input.doc` 就是 UTF-8，不需要任何参数）。按扩展名走对应预转：

```bash
# .doc → 纯文本(中文 UTF-8 默认正常)
antiword input.doc > out.txt

# .xls → CSV(每张 sheet 一段)
xls2csv input.xls > out.csv

# .ppt → 纯文本(每张 slide 一段)
catppt input.ppt > out.txt
```

判别一致用 `file` 头检测，不依赖扩展名：

```bash
case "$(file -b --mime-type "$f")" in
  application/msword)                 antiword "$f" > out.txt ;;
  application/vnd.ms-excel)           xls2csv  "$f" > out.csv ;;
  application/vnd.ms-powerpoint)      catppt   "$f" > out.txt ;;
  *)                                  markitdown "$f" -o out.md ;;
esac
```

注意:
- `antiword` 提纯文本(段落 + 简单表格),不保留 markdown 表语法;有保真表格/图片需求请用 `libreoffice --headless --convert-to docx`(镜像未装,需先 `apt install libreoffice`,代价 +300MB,默认不上)。
- `xls2csv` 多 sheet 时一次性输出,sheet 间会有空行分隔;后续若要喂 `data-analysis`,先按空行切分。

## 输出处理

- 如果文档很长（>20k tokens），先 `head -200 out.md` 看结构再决定是否分段；
- 表格会保留 markdown table 语法，可直接喂给 `data-analysis` 进一步分析；
- 图片描述保留为 `![alt](path)`，alt 文本由 markitdown OCR/captioning 生成。

## 安装与依赖

镜像已 `pip install 'markitdown[all]'`，包含全部格式支持。如缺某格式，重装：

```bash
pip install --upgrade 'markitdown[all]'
```

## 故障排查

| 现象 | 解决 |
| --- | --- |
| `Could not parse: ...` | 文件损坏或加密；先 `file <path>` 看是否真为目标格式 |
| `.doc` markitdown 报无内容 / `cat` 出二进制 | legacy OLE2 格式；改用 `antiword <input> > out.txt`，见上方「legacy Office 处理」 |
| OCR 出来全是乱码 | 图片质量差或非 UTF-8 字体；考虑先用 ImageMagick 预处理 |
| YouTube URL 拿不到字幕 | 视频未生成英文字幕；用 `yt-dlp --write-auto-subs` 抓自动字幕 |
