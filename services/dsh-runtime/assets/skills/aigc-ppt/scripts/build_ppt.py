#!/usr/bin/env python3
"""
build_ppt.py — 把一份大纲 JSON 直接渲染成 .pptx。

设计原则：
  - 所有文字都是 PPT 文本框（python-pptx TextFrame / Run），
    用 PowerPoint / WPS 打开都是「真实可编辑文本」，不会糊不会乱码。
  - 字体名优先用通用簇：东亚字体 = "Microsoft YaHei"（Win/Mac 默认有，
    Linux 上 PowerPoint 在线打开会 fallback 到 Noto Sans CJK），
    西文 = "Calibri"（通用商务字体）。
  - 主题之间只换配色，不换排版/字号，保证字数估计一致。

用法：
    python3 build_ppt.py --plan plan.json --out deck.pptx [--quiet]

stdout（成功）：
    {"file":"deck.pptx","slides":10}

失败：exit code != 0；stderr 写人类可读 error。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Iterable

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.util import Emu, Inches, Pt


# ----------------------- 主题 -----------------------

@dataclass
class Theme:
    name: str
    bg: RGBColor          # 页背景
    accent: RGBColor      # 主标题 / 强调色
    title: RGBColor       # 普通页标题
    body: RGBColor        # 正文
    side_bar: RGBColor    # 左侧装饰条
    is_dark: bool = False


THEMES: dict[str, Theme] = {
    "business-blue": Theme(
        name="business-blue",
        bg=RGBColor(0xFF, 0xFF, 0xFF),
        accent=RGBColor(0x1F, 0x4E, 0x9D),       # 深蓝
        title=RGBColor(0x10, 0x18, 0x28),
        body=RGBColor(0x33, 0x40, 0x52),
        side_bar=RGBColor(0x1F, 0x4E, 0x9D),
    ),
    "dark-tech": Theme(
        name="dark-tech",
        bg=RGBColor(0x0E, 0x14, 0x1B),           # 深背景
        accent=RGBColor(0x4F, 0xC3, 0xF7),       # 青亮色
        title=RGBColor(0xF1, 0xF5, 0xF9),
        body=RGBColor(0xCB, 0xD5, 0xE1),
        side_bar=RGBColor(0x4F, 0xC3, 0xF7),
        is_dark=True,
    ),
    "clean-light": Theme(
        name="clean-light",
        bg=RGBColor(0xFF, 0xFF, 0xFF),
        accent=RGBColor(0x11, 0x18, 0x27),       # 近黑
        title=RGBColor(0x10, 0x18, 0x28),
        body=RGBColor(0x47, 0x55, 0x67),
        side_bar=RGBColor(0x94, 0xA3, 0xB8),
    ),
    "warm-orange": Theme(
        name="warm-orange",
        bg=RGBColor(0xFB, 0xF7, 0xF1),           # 米白
        accent=RGBColor(0xD9, 0x6A, 0x1B),       # 暖橙
        title=RGBColor(0x44, 0x2A, 0x10),
        body=RGBColor(0x5E, 0x49, 0x32),
        side_bar=RGBColor(0xD9, 0x6A, 0x1B),
    ),
}


# 通用字体名：Win/Mac 客户端打开必有；Linux 客户端 fallback 到 CJK 簇。
EAST_ASIAN_FONT = "Microsoft YaHei"
LATIN_FONT = "Calibri"


# ----------------------- 工具 -----------------------

def _set_run(run, *, size_pt: float, bold: bool = False, color: RGBColor | None = None):
    run.font.size = Pt(size_pt)
    run.font.bold = bold
    run.font.name = LATIN_FONT
    # 东亚字体单独设置；python-pptx 1.0+ 支持 east_asian_font_name
    rPr = run._r.get_or_add_rPr()
    # 显式声明东亚字体，避免 PowerPoint 用 Latin 字体强行渲染中文 → 乱码
    eastAsia = rPr.find(
        "{http://schemas.openxmlformats.org/drawingml/2006/main}eastAsia"
    )
    if eastAsia is None:
        from lxml import etree  # python-pptx 已带 lxml 依赖
        eastAsia = etree.SubElement(
            rPr,
            "{http://schemas.openxmlformats.org/drawingml/2006/main}eastAsia",
        )
    eastAsia.set("typeface", EAST_ASIAN_FONT)
    if color is not None:
        run.font.color.rgb = color


def _add_solid_bg(slide, theme: Theme):
    """整页填一个底色矩形，铺满 slide。"""
    width = slide.part.package.presentation_part.presentation.slide_width
    height = slide.part.package.presentation_part.presentation.slide_height
    shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, width, height)
    shape.fill.solid()
    shape.fill.fore_color.rgb = theme.bg
    shape.line.fill.background()
    # 把它沉到最底层，避免遮住后面要加的标题/正文
    spTree = shape._element.getparent()
    spTree.remove(shape._element)
    spTree.insert(2, shape._element)


def _add_side_bar(slide, theme: Theme, slide_height: Emu):
    """左侧 6pt 宽装饰竖条，强化品牌感。"""
    bar = slide.shapes.add_shape(
        MSO_SHAPE.RECTANGLE, Inches(0), Inches(0), Inches(0.12), slide_height
    )
    bar.fill.solid()
    bar.fill.fore_color.rgb = theme.side_bar
    bar.line.fill.background()


def _add_text_box(
    slide,
    *,
    left: Emu,
    top: Emu,
    width: Emu,
    height: Emu,
    text: str,
    size_pt: float,
    bold: bool = False,
    color: RGBColor | None = None,
    align: int = PP_ALIGN.LEFT,
    anchor: int = MSO_ANCHOR.TOP,
):
    box = slide.shapes.add_textbox(left, top, width, height)
    tf = box.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    p = tf.paragraphs[0]
    p.alignment = align
    run = p.add_run()
    run.text = text or ""
    _set_run(run, size_pt=size_pt, bold=bold, color=color)
    return tf


def _add_bullets(
    slide,
    *,
    left: Emu,
    top: Emu,
    width: Emu,
    height: Emu,
    bullets: Iterable[str],
    theme: Theme,
):
    """正文要点：每行一个 bullet，行首用「•」字符（兼容性最好）。"""
    box = slide.shapes.add_textbox(left, top, width, height)
    tf = box.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = MSO_ANCHOR.TOP
    first = True
    for line in bullets:
        line = (line or "").strip()
        if not line:
            continue
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.alignment = PP_ALIGN.LEFT
        p.space_after = Pt(8)
        run = p.add_run()
        run.text = f"•  {line}"
        _set_run(run, size_pt=20, bold=False, color=theme.body)


# ----------------------- 页布局 -----------------------

def _slide_size(aspect_ratio: str) -> tuple[Emu, Emu]:
    if aspect_ratio == "4:3":
        return Inches(10), Inches(7.5)
    return Inches(13.333), Inches(7.5)  # 16:9 默认


def _add_cover(prs: Presentation, theme: Theme, title: str, subtitle: str):
    blank = prs.slide_layouts[6]
    slide = prs.slides.add_slide(blank)
    _add_solid_bg(slide, theme)
    _add_side_bar(slide, theme, prs.slide_height)

    # 大标题：水平居左，垂直居中偏上。
    _add_text_box(
        slide,
        left=Inches(0.8),
        top=Inches(2.4),
        width=prs.slide_width - Inches(1.6),
        height=Inches(1.6),
        text=title or "未命名演示文稿",
        size_pt=44,
        bold=True,
        color=theme.accent,
    )
    if subtitle:
        _add_text_box(
            slide,
            left=Inches(0.8),
            top=Inches(4.0),
            width=prs.slide_width - Inches(1.6),
            height=Inches(1.0),
            text=subtitle,
            size_pt=22,
            bold=False,
            color=theme.body,
        )

    # 右下角小字：自动写一个生成时间，不会出现在图片里所以无所谓
    import datetime
    _add_text_box(
        slide,
        left=Inches(0.8),
        top=prs.slide_height - Inches(0.7),
        width=prs.slide_width - Inches(1.6),
        height=Inches(0.4),
        text=datetime.date.today().strftime("Generated %Y-%m"),
        size_pt=10,
        color=theme.body,
    )


def _add_content(prs: Presentation, theme: Theme, slide_data: dict):
    blank = prs.slide_layouts[6]
    slide = prs.slides.add_slide(blank)
    _add_solid_bg(slide, theme)
    _add_side_bar(slide, theme, prs.slide_height)

    title = slide_data.get("title") or ""
    bullets = slide_data.get("bullets") or []
    if isinstance(bullets, str):
        bullets = [bullets]

    # 页标题：上方 1.0 寸开始
    _add_text_box(
        slide,
        left=Inches(0.7),
        top=Inches(0.8),
        width=prs.slide_width - Inches(1.4),
        height=Inches(1.0),
        text=title,
        size_pt=30,
        bold=True,
        color=theme.title,
    )

    # 标题下细线（视觉锚点）
    line = slide.shapes.add_shape(
        MSO_SHAPE.RECTANGLE, Inches(0.7), Inches(1.85), Inches(0.7), Inches(0.05)
    )
    line.fill.solid()
    line.fill.fore_color.rgb = theme.accent
    line.line.fill.background()

    # 正文 bullets
    _add_bullets(
        slide,
        left=Inches(0.7),
        top=Inches(2.2),
        width=prs.slide_width - Inches(1.4),
        height=prs.slide_height - Inches(2.6),
        bullets=bullets,
        theme=theme,
    )

    # speaker notes
    note = (slide_data.get("note") or "").strip()
    if note:
        notes_tf = slide.notes_slide.notes_text_frame
        notes_tf.text = note


# ----------------------- 入口 -----------------------

def build(plan_path: str, out_path: str) -> dict:
    with open(plan_path, "r", encoding="utf-8") as f:
        plan = json.load(f)

    theme_name = (plan.get("theme") or "business-blue").strip()
    theme = THEMES.get(theme_name, THEMES["business-blue"])

    prs = Presentation()
    sw, sh = _slide_size(plan.get("aspect_ratio", "16:9"))
    prs.slide_width = sw
    prs.slide_height = sh

    title = (plan.get("title") or "").strip()
    subtitle = (plan.get("subtitle") or "").strip()
    _add_cover(prs, theme, title, subtitle)

    slides = plan.get("slides") or []
    for s in slides:
        if not isinstance(s, dict):
            continue
        _add_content(prs, theme, s)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    prs.save(out_path)
    return {
        "file": os.path.abspath(out_path),
        "slides": 1 + len(slides),  # 含封面
        "theme": theme.name,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a Chinese-friendly PPT from a plan JSON.")
    parser.add_argument("--plan", required=True, help="path to plan JSON file")
    parser.add_argument("--out", required=True, help="output .pptx path")
    parser.add_argument("--quiet", action="store_true", help="suppress stdout JSON on success")
    args = parser.parse_args()

    try:
        result = build(args.plan, args.out)
    except FileNotFoundError as e:
        print(f"aigc-ppt: plan file not found: {e}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as e:
        print(f"aigc-ppt: plan JSON invalid: {e}", file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001  让 agent 看到具体错误
        print(f"aigc-ppt: build failed: {e}", file=sys.stderr)
        return 1

    if not args.quiet:
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
