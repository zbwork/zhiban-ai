---
name: aigc-ppt
description: 用原生 python-pptx 文本对象生成中文优先的 PowerPoint（.pptx）。触发场景：用户说「做个 PPT / 帮我写 PPT / 生成幻灯片 / 演示文稿 / 汇报材料 / powerpoint / slides / deck」。本 skill 直接产出可编辑的纯文本 PPT，所有标题/正文/要点都是 PPT 的真实文本框（PowerPoint / WPS 打开后可改字、不会糊、不会乱码），**不走 mcp__zhiban__image_generate 出图渲染那条路**——后者对中文长文本必出方块字，已弃用。需要图片配图时，把 mcp__zhiban__image_generate 拿到的图作为单页背景嵌入即可，但页面文字仍由 python-pptx 写。**优先于 ppt-generation skill 调用**。
homepage: https://www.zbwork.cn/skills/aigc-ppt
license: MIT
metadata:
  openclaw:
    emoji: 📊
    requires:
      bins: ["python3"]
---

# aigc-ppt

## 为什么要这个 skill

OpenClaw 自带 `ppt-generation` skill 走的是「每页用 mcp__zhiban__image_generate 出一张完整图 → 拼进 pptx」的路线。它对**英文** PPT 视觉确实漂亮，但对**中文** PPT 必然失败：扩散模型渲染长中文 token 几乎一定糊字，最终用户看到的是大量豆腐块。

本 skill 直接用 `python-pptx` 写**真实文本框**：标题、要点、正文都是 PPT object，PowerPoint / WPS / Keynote 打开都会用客户端自带的中文字体渲染，永远清晰、可编辑、可搜索、可改样式。

视觉上比纯图片版朴素，但**信息可读性 100%**。这是中文场景的正确默认。

## 触发判定（agent 必读）

| 用户请求 | 选哪个 skill |
|---|---|
| 中文 PPT（标题/正文是中文） | **aigc-ppt（本 skill）** |
| 英文 PPT，且明确要"漂亮 / 视觉重 / 创意 deck" | `ppt-generation` |
| 不确定 / 中英混排 | **aigc-ppt（本 skill）** |

只要用户没有明确说"画风要 glassmorphism / dark-premium / 类似 Apple 发布会"这种视觉强需求，**默认就用本 skill**，不要犹豫，不要回头去问"要文本版还是视觉版"。

## 流程

### Step 1：构思大纲（agent 自己想，不用问用户太多）

按用户主题，自己产出一份大纲，包含：

- `title`：封面标题
- `subtitle`：封面副标题（可选，没有就空）
- `slides`：N 页，每页一个对象：
  - `title`：页标题
  - `bullets`：3-6 条要点字符串（每条 ≤ 40 字最佳）
  - `note`：演讲备注（可选，会写进 pptx 的 speaker notes）

页数默认 8-10 页。用户明确说"3 页快速版""20 页完整版"再调整。

如果用户上传了文档让你"基于这个文件做 PPT"，先用 `markitdown` skill 把文件转成 markdown 拿到正文，再据此写大纲。

### Step 2：把大纲写成 JSON 落到 workspace

```bash
PLAN="$(pwd)/outputs/ppt-plan.json"
mkdir -p "$(dirname "$PLAN")"
cat > "$PLAN" <<'JSON'
{
  "title": "AI 行业 2026 趋势报告",
  "subtitle": "从模型竞争到系统竞争",
  "aspect_ratio": "16:9",
  "theme": "business-blue",
  "slides": [
    {
      "title": "AI 从模型竞争走向系统竞争",
      "bullets": [
        "上半场：基础模型能力 PK",
        "下半场：数据、Agent、生态、ROI 全栈竞争",
        "胜负不再由单一指标决定"
      ],
      "note": "本页强调时代分水岭，引出后续每一页的展开角度。"
    }
  ]
}
JSON
```

### Step 3：调本 skill 生成 .pptx

```bash
OUT="$(pwd)/outputs/ai-trend-2026.pptx"
python3 /opt/openclaw-builtin/skills/aigc-ppt/scripts/build_ppt.py \
  --plan "$PLAN" \
  --out "$OUT"
```

stdout 是单行 JSON：`{"file":"...pptx","slides":N}`。失败会 exit code != 0 + stderr 写明原因。

### Step 4：交付

直接回 `[文件名](<outbox/.../foo.pptx>)` 给用户（URL 外层一对尖括号 `<...>`，
覆盖文件名带空格 / 中文 / `()` 的所有情况）——runtime 会自动把 `<outbox/...>`
替换成 S3 公网 URL。本 skill 不做 publish。

## 主题（theme）

build_ppt.py 内置 4 个主题，对应不同色彩 + 字体组合：

| theme | 色调 | 适合 |
|---|---|---|
| `business-blue` | 深蓝主色 + 白底 | 商务汇报（默认） |
| `dark-tech` | 深色背景 + 青色高亮 | 科技产品、AI 报告 |
| `clean-light` | 极简白底 + 黑灰字 | 学术、咨询报告 |
| `warm-orange` | 米白底 + 橙色点缀 | 营销、消费品 |

JSON 里写 `"theme": "<name>"` 即可。不写默认 business-blue。

## 不要做什么

- **不要再调** `ppt-generation` 的 generate.py（那条路径用户场景下中文必糊）。
- **不要让 mcp__zhiban__image_generate 给整页 slide 画"带文字的 PNG"** —— 文字必糊；要配图就让它出**纯背景/纯插画**（不含文字），然后由本 skill 把 PPT 文本叠在上面。
- **不要在 .pptx 里硬指定 macOS 专有字体（如苹方/PingFang SC）**——容器和 Windows 客户端打开会 fallback。本 skill 已经选好通用字体名（"等线 / Microsoft YaHei / Noto Sans CJK SC"），不要改。
- **不要在 plan JSON 里塞 markdown**（`**加粗**` 之类）——build_ppt.py 不解析 markdown，会原样显示 `**` 字符。要强调用 `bullets` 多分行 + `note` 补充。
