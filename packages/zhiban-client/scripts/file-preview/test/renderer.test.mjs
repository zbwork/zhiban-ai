import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";
import JSZip from "jszip";
import ExcelJS from "exceljs";
import PptxGenJS from "pptxgenjs";
import { PDFDocument, StandardFonts } from "pdf-lib";

test(
  "bundled viewer renders real files and isolates HTML scripts",
  { timeout: 120000 },
  async () => {
    const browser = await chromium.launch({
      headless: true,
      channel: process.env.PREVIEW_BROWSER_CHANNEL || undefined,
    });
    try {
      const page = await browser.newPage({
        viewport: { width: 850, height: 600 },
      });
      const html = await readFile(
        new URL("../../../assets/file_preview/viewer.html", import.meta.url),
        "utf8",
      );
      const errors = [];
      page.on("pageerror", (e) => {
        errors.push(e.message);
        console.error(e.message);
      });
      page.on("console", (m) => {
        if (m.type() === "error") console.error(m.text());
      });
      async function render(format, bytes, name = `sample.${format}`) {
        console.log("Rendering", format);
        await page.goto("about:blank");
        await page.setContent(html);
        await page.waitForFunction(
          () => typeof window.previewFile === "function",
        );
        const result = await page.evaluate(
          (payload) => window.previewFile(payload),
          { format, base64: Buffer.from(bytes).toString("base64"), name },
        );
        assert.equal(
          result,
          "ready",
          await page.locator("#content").innerText(),
        );
        console.log("Rendered", format);
        // Each format shares a compact bar; groups wrap without hiding controls.
        await page.waitForFunction(() => Math.abs(document.querySelector('#content').getBoundingClientRect().bottom - innerHeight) < 2);
        assert.ok(await page.locator('#tools').evaluate(el => el.offsetHeight <= 38));
        await page.setViewportSize({width: 320, height: 600});
        await page.waitForFunction(() => Math.abs(document.querySelector('#content').getBoundingClientRect().bottom - innerHeight) < 2);
        assert.ok(await page.locator('#tools').evaluate(el => el.scrollWidth <= el.clientWidth), `${format} toolbar overflow`);
        for (const control of await page.locator('#tools button, #tools select').all()) {
          const bounds = await control.boundingBox();
          assert.ok(bounds && bounds.x >= 0 && bounds.x + bounds.width <= 321, `${format} hidden control`);
        }
        await page.evaluate(() => document.body.classList.add('dark'));
        assert.equal(await page.locator('#tools').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(35, 40, 50)');
        await page.evaluate(() => document.body.classList.remove('dark'));
        await page.setViewportSize({width: 850, height: 600});
      }
      await render("text", Buffer.from("const answer = 42;"), "sample.ts");
      assert.match(await page.locator("pre").innerText(), /answer = 42/);
      await render(
        "markdown",
        Buffer.from("# Report\n\n| A | B |\n|---|---|\n|1|2|"),
        "sample.md",
      );
      assert.equal(await page.locator("h1").innerText(), "Report");
      assert.equal(await page.locator("table").count(), 1);
      await page.getByRole('button', {name: '源码', exact: true}).click();
      assert.equal(await page.getByRole('button', {name: '源码', exact: true}).getAttribute('aria-pressed'), 'true');
      assert.match(await page.locator('pre').innerText(), /# Report/);
      await page.getByRole('button', {name: '预览', exact: true}).click();
      assert.equal(await page.getByRole('button', {name: '预览', exact: true}).getAttribute('aria-pressed'), 'true');
      await render("markdown", Buffer.from('# Links\n\n[Source](https://example.com/report)\n\n![Chart](images/chart.png)'));
      assert.match(await page.locator('.resource-unavailable').innerText(), /Chart/);
      await page.evaluate(() => { window.openedLinks = []; window.flutter_inappwebview = {callHandler: (...args) => window.openedLinks.push(args)}; });
      await page.getByRole('link', {name: 'Source', exact: true}).click();
      assert.deepEqual(await page.evaluate(() => window.openedLinks), [['openPreviewLink', 'https://example.com/report']]);
      await render("video", await readFile(new URL('./fixtures/preview.mp4', import.meta.url)), 'sample.mp4');
      assert.equal(await page.locator('video').evaluate(v => v.paused), true);
      await page.getByRole('button', {name: '播放', exact: true}).click();
      await page.waitForFunction(() => document.querySelector('video').currentTime > 0);
      await page.getByRole('button', {name: '暂停', exact: true}).click();
      await page.getByRole('slider', {name: '播放进度', exact: true}).fill('0.6');
      await page.getByRole('button', {name: '静音', exact: true}).click();
      assert.equal(await page.locator('video').evaluate(v => v.muted), true);
      await page.getByRole('button', {name: '取消静音', exact: true}).click();
      assert.equal(await page.locator('video').evaluate(v => v.muted), false);
      await page.waitForFunction(() => Math.abs(document.querySelector('video').currentTime - 0.6) < 0.1);
      await page.evaluate(() => { window.previousVideo = document.querySelector('video'); });
      assert.equal(await page.evaluate(() => window.previewFile({format:'markdown', name:'next.md', base64:btoa('# Next')})), 'ready');
      assert.deepEqual(await page.evaluate(() => [window.previousVideo.paused, window.previousVideo.getAttribute('src'), window.previousVideo.isConnected]), [true, null, false]);
      assert.equal(await page.evaluate(() => window.previewFile({format:'video', name:'broken.mp4', base64:btoa('not a video')})), 'error');
      assert.match(await page.locator('.status').innerText(), /视频/);
      await render(
        "image",
        Buffer.from(
          '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="blue"/></svg>',
        ),
        "sample.svg",
      );
      assert.ok(await page.locator("img").evaluate((x) => x.naturalWidth > 0));
      const imageWidth = await page.locator("img").evaluate(x => x.getBoundingClientRect().width);
      await page.getByRole("button", { name: "+", exact: true }).click();
      assert.ok(await page.locator("img").evaluate(x => x.getBoundingClientRect().width) > imageWidth);
      await page.getByRole("button", { name: "重置", exact: true }).click();
      assert.equal(await page.locator("img").evaluate(x => x.getBoundingClientRect().width), imageWidth);
      await page.getByRole("button", { name: "旋转", exact: true }).click();
      const rotated = await page.locator(".image-stage").evaluate(stage => {
        const image = stage.querySelector("img").getBoundingClientRect(), bounds = stage.getBoundingClientRect();
        return {top: image.top - bounds.top, left: image.left - bounds.left, height: image.height, allocatedHeight: bounds.height};
      });
      assert.ok(Math.abs(rotated.top) < 1 && Math.abs(rotated.left) < 1, 'rotated image stays inside its scrollable bounds');
      assert.ok(Math.abs(rotated.height - rotated.allocatedHeight) < 1);
      await page.getByRole("button", { name: "向左旋转", exact: true }).click();
      assert.equal(await page.locator("img").evaluate(x => x.getBoundingClientRect().width), imageWidth);
      await page.getByRole("button", { name: "重置", exact: true }).click();
      await render(
        "html",
        Buffer.from(
          '<button onclick="this.textContent=\'Done\'">Run</button><script>try{parent.document.body.dataset.escaped="yes"}catch{}</script>',
        ),
      );
      await page
        .frameLocator("iframe")
        .getByRole("button", { name: "Run" })
        .click();
      assert.equal(
        await page.frameLocator("iframe").getByRole("button").innerText(),
        "Done",
      );
      assert.equal(
        await page.locator("body").getAttribute("data-escaped"),
        null,
      );
      const book = new ExcelJS.Workbook();
      const sales = book.addWorksheet("销售");
      sales.addRow(["Revenue", 1250]);
      sales.addRow(['Calculated', {formula:'B1*2', result:2500}]);
      sales.addRow(['No cache', {formula:'B1*3'}]);
      sales.getCell('A2001').value = 'Beyond preview limit';
      book.addWorksheet("详情").addRow(["Details"]);
      await render("xlsx", await book.xlsx.writeBuffer());
      assert.match(await page.locator("table").innerText(), /1250/);
      assert.match(await page.locator("table").innerText(), /2500/);
      assert.match(await page.locator("table").innerText(), /无缓存计算结果/);
      assert.match(await page.locator('#content').innerText(), /2000 行/);
      assert.doesNotMatch(await page.locator('table').innerText(), /Beyond preview limit/);
      await page.locator("select").selectOption({ label: "详情" });
      assert.match(await page.locator("table").innerText(), /Details/);
      const zip = new JSZip();
      zip.file(
        "[Content_Types].xml",
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
      );
      zip.file(
        "_rels/.rels",
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
      );
      zip.file(
        "word/document.xml",
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Quarterly report</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>',
      );
      const docxBytes = await zip.generateAsync({ type: "nodebuffer" });
      await render("docx", docxBytes);
      assert.match(
        await page.locator("#content").innerText(),
        /Quarterly report/,
      );
      const race = await page.evaluate(async (base64) => {
        const previous = window.previewFile({format: 'docx', name: 'old.docx', base64});
        const current = window.previewFile({format: 'markdown', name: 'current.md', base64: btoa('# Current file')});
        return Promise.all([previous, current]);
      }, docxBytes.toString('base64'));
      assert.deepEqual(race, ['cancelled', 'ready']);
      assert.equal(await page.locator('#content').innerText(), 'Current file');
      assert.equal(await page.getByRole('button', {name: '›', exact: true}).count(), 0);
      const deck = new PptxGenJS();
      deck.layout = "LAYOUT_WIDE";
      deck.addSlide().addText("Quarterly overview", {
        x: 1,
        y: 1,
        w: 10,
        h: 1,
        fontSize: 32,
        color: "17324D",
      });
      deck
        .addSlide()
        .addText("Second slide", { x: 1, y: 1, w: 10, h: 1, fontSize: 28 });
      await render("pptx", await deck.write({ outputType: "nodebuffer" }));
      assert.match(
        await page.locator("#content").innerText(),
        /Quarterly overview/,
      );
      await page.getByRole("button", { name: "›", exact: true }).click();
      await page.waitForTimeout(200);
      assert.match(await page.locator("#content").innerText(), /Second slide/);
      await page.waitForFunction(
        () => document.querySelector("#content").scrollTop > 100,
      );
      const output = new URL(
        "../../../../../output/playwright/",
        import.meta.url,
      );
      await mkdir(output, { recursive: true });
      await page.screenshot({
        path: fileURLToPath(new URL("zhiban-file-preview-pptx.png", output)),
      });
      // The mobile variant reuses the same bytes but renders one slide and real thumbnails.
      await page.setViewportSize({width: 390, height: 640});
      const mobileDeck = await deck.write({ outputType: "nodebuffer" });
      assert.equal(await page.evaluate(payload => window.previewFile(payload), {
        format: 'pptx', name: 'mobile.pptx', base64: Buffer.from(mobileDeck).toString('base64'), mobile: true,
      }), 'ready');
      await page.waitForFunction(() => document.querySelector('#slide-thumbnails button[aria-current="true"]'));
      assert.equal(await page.locator('#slide-thumbnails button').count(), 2);
      assert.match(await page.locator('#content').innerText(), /Quarterly overview/);
      assert.doesNotMatch(await page.locator('#content').innerText(), /Second slide/);
      await page.getByRole('button', {name: '第 2 页', exact: true}).click();
      await page.waitForFunction(() => document.querySelector('#content').textContent.includes('Second slide'));
      assert.equal(await page.getByRole('button', {name: '第 2 页', exact: true}).getAttribute('aria-current'), 'true');
      await page.getByRole('combobox', {name: '缩放', exact: true}).selectOption('1');
      for (const control of await page.locator('#tools button').all()) {
        const rect = await control.boundingBox();
        assert.ok(rect.height >= 44 && rect.width >= 44, 'mobile touch size');
      }
      await page.setViewportSize({width: 320, height: 640});
      assert.ok(await page.locator('#tools').evaluate(el => el.scrollWidth <= el.clientWidth));
      await page.screenshot({path: fileURLToPath(new URL('zhiban-mobile-preview-pptx.png', output))});
      await page.setViewportSize({width: 850, height: 600});
      const pdf = await PDFDocument.create();
      const font = await pdf.embedFont(StandardFonts.Helvetica);
      pdf.addPage().drawText("PDF report", { x: 50, y: 700, font, size: 24 });
      await render("pdf", await pdf.save());
      assert.equal(await page.locator("#slide-thumbnails").count(), 0, "switch releases thumbnails");
      await page.waitForFunction(
        () => document.querySelector("canvas")?.dataset.rendered === "true",
      );
      assert.equal(await page.locator("canvas").count(), 1);
      await page.goto("about:blank");
      await page.setContent(html);
      await page.waitForFunction(
        () => typeof window.previewFile === "function",
      );
      assert.equal(
        await page.evaluate(() =>
          window.previewFile({
            format: "docx",
            base64: btoa("bad zip"),
            name: "broken.docx",
          }),
        ),
        "error",
      );
      assert.ok((await page.locator(".status").innerText()).length > 0);
      assert.deepEqual(errors, []);
    } finally {
      await browser.close();
    }
  },
);
