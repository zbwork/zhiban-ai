import {
  buildPresentation,
  parseZipLazyMedia,
  PptxViewer,
  RECOMMENDED_ZIP_LIMITS,
} from "@aiden0z/pptx-renderer";
import { renderAsync } from "docx-preview";
import ExcelJS from "exceljs";
import { getDocument, GlobalWorkerOptions } from "pdfjs-dist";
import { marked } from "marked";
import DOMPurify from "dompurify";
import hljs from "highlight.js/lib/common";
import { unzipSync } from "fflate";

const content = document.getElementById("content"),
  tools = document.getElementById("tools");
let mobilePreview = false;
let cleanups = [],
  pages = [],
  page = 0,
  zoom = 1,
  rotation = 0,
  imageLayout,
  ppt;
const blob = (data, type) => {
  const url = URL.createObjectURL(new Blob([data], { type }));
  cleanups.push(() => URL.revokeObjectURL(url));
  return url;
};
const status = (message) => {
  content.replaceChildren();
  const p = document.createElement("p");
  p.className = "status";
  p.textContent = message;
  content.append(p);
};
// Wrapped toolbar groups report their actual height to the content viewport.
const toolbarObserver = new ResizeObserver(() => {
  document.documentElement.style.setProperty("--tools-height", `${tools.offsetHeight}px`);
});
toolbarObserver.observe(tools);
function group(label) {
  const element = document.createElement("div");
  element.className = "tool-group";
  element.setAttribute("role", "group");
  element.setAttribute("aria-label", label);
  tools.append(element);
  return element;
}
function counter() {
  const element = document.createElement("span");
  element.className = "tool-counter";
  return element;
}
function button(label, action, parent = tools, title = label) {
  const b = document.createElement("button");
  b.textContent = label;
  b.onclick = action;
  b.title = title;
  parent.append(b);
  return b;
}
function pagedToolbar(chapters = []) {
  const outline = chapters.length ? group("目录") : null;
  const selection = outline ? document.createElement("select") : null;
  if (selection) {
    selection.setAttribute("aria-label", "章节");
    for (const chapter of chapters) {
      const option = document.createElement("option");
      option.value = String(chapter.page);
      option.textContent = chapter.title;
      selection.append(option);
    }
    selection.onchange = () => goto(Number(selection.value));
    outline.append(selection);
  }
  const navigation = group("页码");
  const prev = button("‹", () => goto(page - 1), navigation, "上一页");
  const label = counter();
  navigation.append(label);
  const next = button("›", () => goto(page + 1), navigation, "下一页");
  const update = () => {
    label.textContent = `${pages.length ? page + 1 : 0} / ${pages.length}`;
    prev.disabled = page <= 0;
    next.disabled = page >= pages.length - 1;
    if (selection) {
      let active = "";
      for (const chapter of chapters) {
        if (chapter.page > page) break;
        active = String(chapter.page);
      }
      selection.value = active;
    }
  };
  function goto(n) {
    page = Math.min(Math.max(n, 0), pages.length - 1);
    pages[page]?.scrollIntoView({ block: "start" });
    update();
  }
  const onscroll = () => {
    if (selection && content.scrollTop > 0 &&
        content.scrollHeight - content.clientHeight - content.scrollTop <= 2) {
      page = pages.length - 1;
      update();
      return;
    }
    const top = content.getBoundingClientRect().top;
    const n = pages.findIndex(
      (el) => el.getBoundingClientRect().bottom > top + 8,
    );
    if (n >= 0) {
      page = n;
      update();
    }
  };
  content.addEventListener("scroll", onscroll);
  cleanups.push(() => content.removeEventListener("scroll", onscroll));
  update();
  zoomToolbar({ onZoom: chapters.length ? () => goto(page) : null });
}
async function pdfChapters(pdf) {
  const chapters = new Map();
  let visited = 0;
  async function walk(items, depth) {
    if (!items || depth > 8) return;
    for (const item of items) {
      if (++visited > 100) return;
      if (!item.url && item.dest && typeof item.title === "string") {
        const dest = typeof item.dest === "string"
          ? await pdf.getDestination(item.dest).catch(() => null)
          : item.dest;
        const ref = Array.isArray(dest) ? dest[0] : null;
        const index = Number.isInteger(ref) ? ref
          : ref && typeof ref === "object"
            ? await pdf.getPageIndex(ref).catch(() => -1) : -1;
        if (index >= 0 && index < pdf.numPages && !chapters.has(index)) {
          chapters.set(index, { page: index, title: item.title.trim().slice(0, 140) });
        }
      }
      await walk(item.items, depth + 1);
    }
  }
  await walk(await pdf.getOutline().catch(() => null), 0);
  return [...chapters.values()]
    .filter((chapter) => chapter.title)
    .sort((a, b) => a.page - b.page);
}
function zoomToolbar({ rotate = false, onZoom } = {}) {
  if (mobilePreview && ppt) {
    const controls = group('缩放');
    const select = document.createElement('select');
    select.setAttribute('aria-label', '缩放');
    for (const value of [1, 1.25, 1.5, 1.75, 2]) {
      const option = document.createElement('option');
      option.value = String(value);
      option.textContent = value === 1 ? '适合宽度' : `${value * 100}%`;
      select.append(option);
    }
    const apply = () => { select.value = String(zoom); void ppt.setZoom(zoom * 100); };
    select.onchange = () => { zoom = Number(select.value); apply(); };
    controls.append(select);
    button('+', () => { zoom = zoom >= 2 ? 1 : zoom + .25; apply(); }, controls, '放大');
    return;
  }
  const controls = group("缩放");
  const z = counter();
  const apply = () => {
    z.textContent = `${Math.round(zoom * 100)}%`;
    if (imageLayout) imageLayout();
    else if (ppt) ppt.setZoom(zoom * 100);
    else for (const el of content.children) {
      el.style.zoom = zoom;
    }
    onZoom?.();
  };
  button("−", () => {
    zoom = Math.max(0.4, zoom - 0.1);
    apply();
  }, controls, "缩小");
  controls.append(z);
  button("+", () => {
    zoom = Math.min(2, zoom + 0.1);
    apply();
  }, controls, "放大");
  if (rotate) {
    const rotations = group("旋转");
    const left = button("", () => { rotation = (rotation + 270) % 360; apply(); }, rotations, "向左旋转");
    left.setAttribute("aria-label", "向左旋转");
    toolbarIcon(left, "rotateLeft");
    const right = button("", () => { rotation = (rotation + 90) % 360; apply(); }, rotations, "向右旋转");
    right.setAttribute("aria-label", "旋转");
    toolbarIcon(right, "rotateRight");
  }
  button(mobilePreview && ppt ? "适合宽度" : "重置", () => {
    zoom = 1;
    rotation = 0;
    apply();
  }, group("重置"));
  apply();
}
function modeToolbar(label, preview, source) {
  const modes = group("显示方式");
  modes.classList.add("segments");
  const select = (value) => {
    rendered.setAttribute("aria-pressed", String(value));
    code.setAttribute("aria-pressed", String(!value));
    value ? preview() : source();
  };
  const rendered = button(label, () => select(true), modes);
  const code = button("源码", () => select(false), modes);
  rendered.setAttribute("aria-pressed", "true");
  code.setAttribute("aria-pressed", "false");
}
function toolbarIcon(button, kind) {
  const paths = {
    rotateLeft: '<path d="M3 11a9 9 0 1 1 2.64 6.36M3 3v8h8"/>',
    rotateRight: '<path d="M21 11a9 9 0 1 0-2.64 6.36M21 3v8h-8"/>',
    play: '<path d="m8 5 11 7-11 7z"/>',
    pause: '<path d="M8 5v14M16 5v14"/>',
    volume: '<path d="m11 5-5 4H3v6h3l5 4zM15 8a5 5 0 0 1 0 8M18 5a9 9 0 0 1 0 14"/>',
    muted: '<path d="m11 5-5 4H3v6h3l5 4zM16 9l5 6M21 9l-5 6"/>',
  };
  button.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[kind]}</svg>`;
}
function mediaToolbar(media, label) {
  const controls = group(label+"播放");
  controls.classList.add("video-tools");
  const play = button("▶", async () => {
    try { media.paused ? await media.play() : media.pause(); }
    catch { play.title = "无法播放，请重试"; }
  }, controls, "播放");
  const time = counter();
  const formatTime = (seconds) => {
    if (!Number.isFinite(seconds)) return "--:--";
    return `${Math.floor(seconds / 60).toString().padStart(2, "0")}:${Math.floor(seconds % 60).toString().padStart(2, "0")}`;
  };
  controls.append(time);
  const seek = document.createElement("input");
  seek.type = "range";
  seek.className = "seek";
  seek.min = "0";
  seek.step = "0.1";
  seek.setAttribute("aria-label", "播放进度");
  seek.oninput = () => { media.currentTime = Number(seek.value); };
  controls.append(seek);
  const mute = button("♪", () => { media.muted = !media.muted; }, controls, "静音");
  const volume = document.createElement("input");
  volume.type = "range";
  volume.className = "volume";
  volume.min = "0"; volume.max = "1"; volume.step = "0.05";
  volume.setAttribute("aria-label", "音量");
  volume.oninput = () => { media.volume = Number(volume.value); media.muted = media.volume === 0; };
  controls.append(volume);
  const update = () => {
    toolbarIcon(play, media.paused ? "play" : "pause");
    play.title = media.paused ? "播放" : "暂停";
    play.setAttribute("aria-label", play.title);
    time.textContent = `${formatTime(media.currentTime)} / ${formatTime(media.duration)}`;
    seek.disabled = !Number.isFinite(media.duration) || media.duration <= 0;
    seek.max = seek.disabled ? "0" : String(media.duration);
    seek.value = String(media.currentTime);
    seek.setAttribute("aria-valuetext", time.textContent);
    toolbarIcon(mute, media.muted ? "muted" : "volume");
    mute.title = media.muted ? "取消静音" : "静音";
    mute.setAttribute("aria-label", mute.title);
    mute.setAttribute("aria-pressed", String(media.muted));
    volume.value = String(media.muted ? 0 : media.volume);
  };
  const events = ["play", "pause", "ended", "timeupdate", "durationchange", "volumechange"];
  for (const event of events) media.addEventListener(event, update);
  cleanups.push(() => { for (const event of events) media.removeEventListener(event, update); });
  update();
}
function textPreview(source, markdown) {
  const article = document.createElement("article");
  if (markdown)
    article.innerHTML = DOMPurify.sanitize(marked.parse(source), {
      FORBID_TAGS: ["iframe", "form", "input", "button"],
      FORBID_ATTR: ["target"],
    });
  else {
    const pre = document.createElement("pre"),
      code = document.createElement("code");
    code.textContent = source;
    pre.append(code);
    article.append(pre);
    if (source.length < 100000) hljs.highlightElement(code);
  }
  if (markdown) {
    for (const img of article.querySelectorAll('img')) {
      const src = img.getAttribute('src') || '';
      if (!src.startsWith('data:image/') && !src.startsWith('blob:')) {
        const note = document.createElement('span');
        note.className = 'resource-unavailable';
        note.textContent = `图片未嵌入文件${img.alt ? '：' + img.alt : ''}（请下载连同资源查看）`;
        img.replaceWith(note);
      }
    }
  }
  content.replaceChildren(article);
}
function checkZip(bytes) {
  let total = 0,
    count = 0;
  unzipSync(bytes, {
    filter: (entry) => {
      total += entry.originalSize;
      if (
        ++count > 10000 ||
        entry.originalSize > 40 * 1024 * 1024 ||
        total > 100 * 1024 * 1024
      )
        throw Error("文档解压后过大，请在本地应用中打开");
      return false;
    },
  });
}
async function workbook(bytes, generation) {
  const book = new ExcelJS.Workbook();
  await book.xlsx.load(bytes);
  if (generation !== renderGeneration) return;
  const sheets = group("工作表");
  const sheetLabel = document.createElement("span");
  sheetLabel.className = "tool-label";
  sheetLabel.textContent = "工作表";
  const select = document.createElement("select");
  select.setAttribute("aria-label", "工作表");
  sheets.append(sheetLabel, select);
  for (const sheet of book.worksheets) {
    const option = document.createElement("option");
    option.value = sheet.id;
    option.textContent = sheet.name;
    select.append(option);
  }
  const show = () => {
    const sheet = book.getWorksheet(Number(select.value));
    content.replaceChildren();
    if (!sheet) return status("此表格没有工作表");
    const wrap = document.createElement("div");
    wrap.className = "sheet";
    const table = document.createElement("table");
    wrap.append(table);
    content.append(wrap);
    const head = table.createTHead().insertRow();
    head.append(document.createElement("th"));
    const cols = Math.min(sheet.columnCount, 100),
      rows = Math.min(sheet.rowCount, 2000);
    for (let c = 1; c <= cols; c++) {
      const th = document.createElement("th");
      th.textContent = sheet.getColumn(c).letter;
      head.append(th);
    }
    const body = table.createTBody();
    for (let r = 1; r <= rows; r++) {
      const row = body.insertRow();
      const number = document.createElement("th");
      number.textContent = r;
      row.append(number);
      for (let c = 1; c <= cols; c++) {
        const cell = sheet.getCell(r, c),
          td = row.insertCell();
        const value = cell.value;
        td.textContent = value?.formula
          ? String(value.result ?? "（无缓存计算结果）")
          : value instanceof Date
            ? value.toLocaleDateString("zh-CN")
            : cell.text;
        if (cell.font?.bold) td.style.fontWeight = "bold";
        if (cell.font?.italic) td.style.fontStyle = "italic";
        if (cell.font?.color?.argb)
          td.style.color = "#" + cell.font.color.argb.slice(-6);
        if (cell.fill?.fgColor?.argb)
          td.style.backgroundColor = "#" + cell.fill.fgColor.argb.slice(-6);
        if (cell.alignment?.horizontal)
          td.style.textAlign = cell.alignment.horizontal;
        if (cell.isMerged && cell.master.address !== cell.address)
          td.textContent = "";
      }
    }
    if (sheet.rowCount > rows || sheet.columnCount > cols) {
      const note = document.createElement("p");
      note.textContent = "已展示前 2000 行 / 100 列，完整内容请下载查看";
      content.prepend(note);
    }
  };
  select.onchange = () => {
    show();
    // A new sheet must retain the zoom advertised by the shared toolbar.
    for (const element of content.children) element.style.zoom = zoom;
  };
  show();
  zoomToolbar();
}

// Preview handles are limited to visible thumbnails and released on navigation.
function mobileSlideThumbnails(instance, generation) {
  const rail = document.createElement('nav');
  rail.id = 'slide-thumbnails';
  rail.setAttribute('aria-label', '幻灯片缩略图');
  content.after(rail);
  const handles = new Map();
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const tile = entry.target;
      if (!entry.isIntersecting) {
        handles.get(tile)?.dispose();
        handles.delete(tile);
        continue;
      }
      if (!handles.has(tile)) {
        const handle = instance.renderThumbnailToContainer(Number(tile.dataset.index), tile.firstChild, {width: 112});
        if (handle) {
          handles.set(tile, handle);
          Promise.resolve(handle.ready).catch(() => {
            if (generation === renderGeneration) tile.firstChild.textContent = '缩略图暂不可用';
          });
        }
      }
    }
  }, {root: rail, rootMargin: '0px 120px'});
  for (let n = 0; n < instance.slideCount; n++) {
    const tile = button('', async () => {
      await instance.goToSlide(n);
    }, rail, `第 ${n + 1} 页`);
    tile.dataset.index = String(n);
    tile.setAttribute('aria-label', `第 ${n + 1} 页`);
    const preview = document.createElement('div');
    preview.className = 'slide-thumbnail-content';
    const number = document.createElement('span');
    number.textContent = String(n + 1);
    tile.append(preview, number);
    observer.observe(tile);
  }
  cleanups.push(() => {
    observer.disconnect();
    for (const handle of handles.values()) handle.dispose();
    rail.remove();
  });
  return () => {
    for (const tile of rail.children) {
      const current = Number(tile.dataset.index) === instance.currentSlideIndex;
      tile.setAttribute('aria-current', String(current));
      if (current) tile.scrollIntoView({block: 'nearest', inline: 'nearest'});
    }
  };
}

let renderGeneration = 0;
window.previewFile = async ({ base64, format, name, mime = "", dark, palette = {}, mobile = false }) => {
  const generation = ++renderGeneration;
  for (const close of cleanups) close();
  cleanups = [];
  document.getElementById('slide-thumbnails')?.remove();
  mobilePreview = mobile === true;
  document.body.classList.toggle('mobile-preview', mobilePreview);
  document.body.classList.toggle('mobile-ppt', mobilePreview && format === 'pptx');
  ppt = null;
  pages = [];
  page = 0;
  zoom = 1;
  rotation = 0;
  imageLayout = null;
  tools.replaceChildren();
  content.replaceChildren();
  document.body.classList.toggle("dark", !!dark);
  document.body.classList.toggle("image-preview", format === "image");
  document.body.classList.toggle("video-preview", format === "video");
  for (const key of ["paper", "bg", "fg", "muted", "line", "primary", "active"]) {
    const value = palette[key];
    if (typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value))
      document.body.style.setProperty(`--${key}`, value);
    else document.body.style.removeProperty(`--${key}`);
  }
  window.previewState = "loading";
  try {
    const bytes = Uint8Array.from(atob(base64), (x) => x.charCodeAt(0));
    if (["pptx", "docx", "xlsx"].includes(format)) checkZip(bytes);
    if (format === "pptx") {
      const parsed = await parseZipLazyMedia(bytes.buffer, RECOMMENDED_ZIP_LIMITS);
      if (generation !== renderGeneration) return "cancelled";
      const model = buildPresentation(parsed, { lazySlides: true });
      // Give the renderer the inner width, excluding the mobile canvas padding.
      const slideHost = mobilePreview ? document.createElement('div') : content;
      if (mobilePreview) content.append(slideHost);
      ppt = new PptxViewer(slideHost, {
        fitMode: "contain",
        scrollContainer: content,
        lazyMedia: true,
        lazySlides: true,
        pdfjs: false,
        zipLimits: RECOMMENDED_ZIP_LIMITS,
      });
      const instance = ppt;
      cleanups.push(() => instance.destroy());
      ppt.load(model);
      if (mobilePreview) await ppt.renderSlide(0);
      else await ppt.renderList({ windowed: true, batchSize: 3, initialSlides: 3 });
      if (generation !== renderGeneration) return "cancelled";
      const navigation = group("页码");
      const label = counter();
      let selectThumbnail = () => {};
      const update = () => {
        selectThumbnail();
        label.textContent = `${instance.currentSlideIndex + 1} / ${instance.slideCount}`;
        prev.disabled = instance.currentSlideIndex <= 0;
        next.disabled = instance.currentSlideIndex >= instance.slideCount - 1;
      };
      const prev = button("‹", async () => {
        await instance.goToSlide(Math.max(0, instance.currentSlideIndex - 1));
        if (generation === renderGeneration) update();
      }, navigation, "上一页");
      navigation.append(label);
      const next = button("›", async () => {
        await instance.goToSlide(Math.min(instance.slideCount - 1, instance.currentSlideIndex + 1));
        if (generation === renderGeneration) update();
      }, navigation, "下一页");
      content.addEventListener("scroll", update);
      cleanups.push(() => content.removeEventListener("scroll", update));
      if (mobilePreview) selectThumbnail = mobileSlideThumbnails(instance, generation);
      instance.addEventListener('slidechange', update);
      cleanups.push(() => instance.removeEventListener('slidechange', update));
      update();
      zoomToolbar();
    } else if (format === "docx") {
      const documentContent = document.createElement("div");
      await renderAsync(bytes, documentContent, undefined, {
        inWrapper: true,
        breakPages: true,
        renderHeaders: true,
        renderFooters: true,
        renderFootnotes: true,
        useBase64URL: true,
        renderAltChunks: false,
      });
      if (generation !== renderGeneration) return "cancelled";
      content.replaceChildren(...documentContent.childNodes);
      content.querySelectorAll("a").forEach((a) => a.removeAttribute("href"));
      pages = [...content.querySelectorAll("section.docx")];
      if (pages[0]?.offsetWidth) {
        zoom = Math.min(1, (content.clientWidth - 32) / pages[0].offsetWidth);
      }
      pagedToolbar();
    } else if (format === "xlsx") await workbook(bytes, generation);
    else if (format === "pdf") {
      GlobalWorkerOptions.workerSrc = blob(
        window.pdfWorkerSource,
        "text/javascript",
      );
      const task = getDocument({
        data: bytes,
        isEvalSupported: false,
        disableAutoFetch: true,
      });
      cleanups.push(() => task.destroy());
      const pdf = await task.promise;
      const firstPage = await pdf.getPage(1);
      if (generation !== renderGeneration) return "cancelled";
      const placeholder = firstPage.getViewport({ scale: 1.25 });
      const reserveSpace = (canvas, size) => {
        canvas.style.width = `${size.width}px`;
        canvas.style.aspectRatio = `${size.width} / ${size.height}`;
      };
      const observer = new IntersectionObserver(
        (entries) => {
          for (const e of entries) {
            if (!e.isIntersecting) continue;
            observer.unobserve(e.target);
            const n = Number(e.target.dataset.page);
            void pdf
              .getPage(n)
              .then(async (p) => {
                const viewport = p.getViewport({ scale: 1.25 });
                const canvas = e.target;
                reserveSpace(canvas, viewport);
                canvas.width = viewport.width;
                canvas.height = viewport.height;
                await p.render({
                  canvas,
                  canvasContext: canvas.getContext("2d"),
                  viewport,
                }).promise;
                canvas.dataset.rendered = "true";
              })
              .catch(() => {
                e.target.setAttribute("aria-label", "页面渲染失败");
              });
          }
        },
        { root: content, rootMargin: "600px" },
      );
      cleanups.push(() => observer.disconnect());
      for (let n = 1; n <= pdf.numPages; n++) {
        const canvas = document.createElement("canvas");
        canvas.dataset.page = n;
        // Reserve page space before PDF.js renders it so chapter jumps and
        // zoom do not move when later canvases receive their dimensions.
        reserveSpace(canvas, placeholder);
        content.append(canvas);
        pages.push(canvas);
        observer.observe(canvas);
      }
      const chapters = await pdfChapters(pdf);
      if (generation !== renderGeneration) return "cancelled";
      pagedToolbar(chapters);
    } else if (format === "image") {
      const img = document.createElement("img");
      img.alt = name;
      img.src = blob(
        bytes,
        mime.startsWith("image/") && mime !== "image/*"
          ? mime
          : name.toLowerCase().endsWith(".svg")
            ? "image/svg+xml"
            : "application/octet-stream",
      );
      const stage = document.createElement("div");
      stage.className = "image-stage";
      stage.style.position = "relative";
      stage.style.margin = "0 auto";
      stage.append(img);
      content.append(stage);
      await img.decode();
      if (generation !== renderGeneration) return "cancelled";
      imageLayout = () => {
        const turned = rotation % 180 !== 0;
        const available = Math.max(1, content.clientWidth - 24);
        const scale = Math.min(1, available / (turned ? img.naturalHeight : img.naturalWidth)) * zoom;
        const width = img.naturalWidth * scale, height = img.naturalHeight * scale;
        stage.style.width = `${turned ? height : width}px`;
        stage.style.height = `${turned ? width : height}px`;
        Object.assign(img.style, {
          position: "absolute", left: "50%", top: "50%", maxWidth: "none",
          width: `${width}px`, height: `${height}px`, margin: "0",
          transform: `translate(-50%, -50%) rotate(${rotation}deg)`,
        });
      };
      const observer = new ResizeObserver(() => imageLayout?.());
      observer.observe(content);
      cleanups.push(() => observer.disconnect());
      zoomToolbar({ rotate: true });
    } else if (format === "video" || format === "audio") {
      const audio = format === "audio";
      const label = audio ? "音频" : "视频";
      const media = document.createElement(format);
      media.controls = false;
      media.playsInline = true;
      media.preload = 'metadata';
      media.style.width = '100%';
      media.style.maxHeight = '100%';
      media.setAttribute('aria-label', name || label);
      const ext = name.split('.').pop()?.toLowerCase();
      const type = audio ? 'audio/mp4' : mime.startsWith('video/') ? mime : ext === 'webm' ? 'video/webm'
          : ext === 'ogv' ? 'video/ogg' : ext === 'mov' ? 'video/quicktime' : 'video/mp4';
      content.append(media);
      await new Promise((resolve, reject) => {
        let settled = false;
        const finish = (error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          media.onloadedmetadata = null;
          media.onerror = null;
          error ? reject(error) : resolve();
        };
        const timer = setTimeout(() => finish(Error(label+'加载超时，请下载后查看')), 15000);
        media.onloadedmetadata = () => finish();
        media.onerror = () => finish(Error(label+'损坏或当前设备不支持此编码，请下载后查看'));
        cleanups.push(() => {
          finish(Error('预览已切换'));
          media.pause();
          media.removeAttribute('src');
          media.load();
        });
        media.src = blob(bytes, type);
      });
      if (generation !== renderGeneration) return "cancelled";
      mediaToolbar(media, label);
    } else if (format === "html") {
      const frame = document.createElement("iframe");
      frame.sandbox = "allow-scripts";
      frame.title = name;
      const html = new TextDecoder().decode(bytes);
      const policy =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; form-action 'none'\">";
      frame.src = blob(policy + html, "text/html");
      content.append(frame);
      modeToolbar("页面", () => content.replaceChildren(frame), () => textPreview(html, false));
    } else {
      const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      if (source.includes("\0"))
        throw Error("该文件是二进制内容，暂不支持预览");
      textPreview(source, format === "markdown");
      if (format === "markdown") {
        modeToolbar("预览", () => textPreview(source, true), () => textPreview(source, false));
      } else {
        const label = document.createElement("span");
        label.className = "tool-label";
        label.textContent = "纯文本 · UTF-8";
        group("格式").append(label);
      }
    }
    if (generation !== renderGeneration) return "cancelled";
    window.previewState = "ready";
    return "ready";
  } catch (error) {
    if (generation !== renderGeneration) return "cancelled";
    tools.replaceChildren();
    status(error?.message || "文件损坏或格式不受支持，请下载查看");
    window.previewState = "error";
    return "error";
  }
};
document.addEventListener("click", (e) => {
  const link = e.target.closest("a");
  if (!link) return;
  e.preventDefault();
  if (!link.closest('article')) return;
  try {
    const url = new URL(link.getAttribute('href'));
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return;
    window.flutter_inappwebview?.callHandler('openPreviewLink', url.href);
  } catch { /* Relative paths cannot escape the isolated document. */ }
});
