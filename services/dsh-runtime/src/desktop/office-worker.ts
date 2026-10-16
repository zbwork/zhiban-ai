/** One confined process per Office operation. No model loop, shell interpolation or macros. */
import { constants } from 'node:fs';
import { mkdir, open, writeFile } from 'node:fs/promises';
import { dirname, extname } from 'node:path';
import { Document, HeadingLevel, Packer, PageBreak, Paragraph, TextRun } from 'docx';
import ExcelJS from 'exceljs';
import { createRequire } from 'node:module';
import type PptxModule from 'pptxgenjs';
// PptxGenJS 4 exports CJS declarations for both entrypoints; use its matching CJS runtime.
const PptxGenJS = createRequire(import.meta.resolve('pptxgenjs'))('pptxgenjs') as typeof PptxModule.default;
import { OfficeParser } from 'officeparser';
import { officeCreate, officeRead } from './office-schema.js';
import { validateRelativePath } from './artifacts.js';

async function run(): Promise<void> {
  const chunks: Buffer[] = []; let size = 0;
  for await (const chunk of process.stdin) {
    const bytes = Buffer.from(chunk); size += bytes.length;
    if (size > 4 * 1024 * 1024) throw Error('input_limit');
    chunks.push(bytes);
  }
  const raw = Buffer.concat(chunks, size).toString('utf8');
  const command = JSON.parse(raw) as { operation: string; args: unknown };
  if (command.operation === 'read') {
    const args = officeRead.parse(command.args);
    validateRelativePath(args.path);
    if (!['.docx', '.xlsx', '.pptx', '.odt', '.ods', '.odp', '.pdf', '.rtf'].includes(extname(args.path).toLowerCase())) throw Error('unsupported_format');
    const fd = await open(args.path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const stat = await fd.stat();
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > 32 * 1024 * 1024) throw Error('size_limit');
      const bytes = await fd.readFile();
      if (bytes.length !== stat.size) throw Error('file_changed');
      const ast = await OfficeParser.parseOffice(bytes, { ocr: false, extractAttachments: false });
      const { value } = await ast.to('text');
      const text = String(value);
      process.stdout.write(JSON.stringify({ format: ast.type, requires_ocr: ast.type === 'pdf' && text.trim() === '', text: text.slice(args.offset, args.offset + args.max_chars), total_chars: text.length, truncated: args.offset + args.max_chars < text.length }));
    } finally { await fd.close(); }
    return;
  }
  const args = officeCreate.parse(command.args);
  validateRelativePath(args.path);
  if (extname(args.path).toLowerCase() !== `.${args.kind}`) throw Error('extension_mismatch');
  let bytes: Buffer;
  if (args.kind === 'docx') {
    // Form feed is a page break request, but is illegal as a literal XML 1.0 character.
    const paragraphs = args.paragraphs.map((text) => new Paragraph({
      children: text.split('\f').flatMap((part, index) => index === 0 ? [new TextRun(part)] : [new PageBreak(), new TextRun(part)]),
      spacing: { after: 180 },
    }));
    const doc = new Document({ creator: '知办AI', title: args.title, sections: [{ children: [new Paragraph({ text: args.title, heading: HeadingLevel.TITLE }), ...paragraphs] }] });
    bytes = await Packer.toBuffer(doc);
  } else if (args.kind === 'xlsx') {
    const workbook = new ExcelJS.Workbook(); workbook.creator = '知办AI';
    const names = new Set<string>();
    for (const source of args.sheets) {
      if (names.has(source.name.toLowerCase())) throw Error('duplicate_sheet');
      names.add(source.name.toLowerCase());
      const sheet = workbook.addWorksheet(source.name, { views: [{ state: 'frozen', ySplit: 1 }] });
      sheet.columns = source.headers.map((header, index) => ({ header, key: `c${index}`, width: Math.min(40, Math.max(16, header.length * 2 + 4)) }));
      sheet.getRow(1).font = { bold: true, color: { argb: 'FFFFFFFF' } };
      sheet.getRow(1).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF1F3D5B' } };
      for (const values of source.rows) {
        if (values.length > source.headers.length) throw Error('column_mismatch');
        sheet.addRow(values);
      }
      sheet.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: source.headers.length } };
    }
    bytes = Buffer.from(await workbook.xlsx.writeBuffer());
  } else {
    const pptx = new PptxGenJS(); pptx.layout = 'LAYOUT_WIDE'; pptx.author = '知办AI'; pptx.title = args.title;
    pptx.theme = { headFontFace: 'Microsoft YaHei', bodyFontFace: 'Microsoft YaHei' };
    for (const [index, source] of args.slides.entries()) {
      const slide = pptx.addSlide(); slide.background = { color: 'F8FAFC' };
      slide.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: 0.16, h: 7.5, fill: { color: '1F3D5B' }, line: { color: '1F3D5B' } });
      slide.addText(source.title, { x: 0.7, y: 0.6, w: 11.8, h: 1.0, fontSize: 30, bold: true, color: '183048', fit: 'shrink', breakLine: false });
      slide.addText(source.bullets.map((text) => ({ text, options: { bullet: { indent: 20 }, breakLine: true } })), { x: 0.85, y: 1.9, w: 11.5, h: 4.7, fontSize: 21, color: '344256', paraSpaceAfter: 18, valign: 'top', fit: 'shrink' });
      slide.addText(String(index + 1), { x: 11.7, y: 7.0, w: 0.7, h: 0.25, fontSize: 10, align: 'right', color: '6B7280' });
      if (source.notes) slide.addNotes(source.notes);
    }
    bytes = Buffer.from(await pptx.write({ outputType: 'nodebuffer', compression: true }) as Uint8Array);
  }
  if (bytes.length > 32 * 1024 * 1024 || bytes.subarray(0, 2).toString() !== 'PK') throw Error('invalid_output');
  await mkdir(dirname(args.path), { recursive: true });
  await writeFile(args.path, bytes, { flag: 'wx' });
  const summary = args.kind === 'docx' ? { title: args.title, paragraphs: args.paragraphs.length }
    : args.kind === 'pptx' ? { title: args.title, slides: args.slides.length }
    : { sheets: args.sheets.map(sheet => ({ name: sheet.name, rows: sheet.rows.length, columns: sheet.headers.length })) };
  process.stdout.write(JSON.stringify({ path: args.path, size: bytes.length, format: args.kind, summary }));
}

void run().catch((error: unknown) => {
  const code = (error as NodeJS.ErrnoException)?.code;
  const reason = error instanceof Error ? error.message : '';
  const safe = code === 'EEXIST' ? 'local.office_file_exists'
    : code === 'ENOENT' ? 'local.office_file_missing'
    : code === 'EACCES' || code === 'EPERM' ? 'local.office_access_denied'
    : ['unsupported_format', 'extension_mismatch', 'duplicate_sheet', 'column_mismatch'].includes(reason) ? 'local.office_invalid_format'
    : 'local.office_operation_failed';
  process.stderr.write(`${safe}\n`); process.exitCode = 1;
});
