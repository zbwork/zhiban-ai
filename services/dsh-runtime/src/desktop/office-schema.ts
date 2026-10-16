import { z } from 'zod';

const path = z.string().min(1).max(2048);
const cell = z.union([z.string().max(10000), z.number().finite(), z.boolean(), z.null()]);
// XML 1.0 disallows these controls; keep the explicit range for validation.
// eslint-disable-next-line no-control-regex
const invalidXmlControl = /[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]/;
const rejectInvalidXmlControls = (value: unknown, ctx: z.RefinementCtx): void => {
  const walk = (item: unknown, path: (string | number)[]) => {
    const allowPageBreak = path.length >= 2 && path[path.length - 2] === 'paragraphs';
    if (typeof item === 'string' && [...item].some((char) => invalidXmlControl.test(char) && !(char === '\f' && allowPageBreak))) ctx.addIssue({ code: 'custom', path, message: allowPageBreak ? '文本包含 XML 不支持的控制字符（仅允许使用 \\f 换页）' : '文本包含 XML 不支持的控制字符；仅 DOCX 正文段落允许使用 \\f 换页' });
    else if (Array.isArray(item)) item.forEach((child, index) => walk(child, [...path, index]));
    else if (item && typeof item === 'object') Object.entries(item).forEach(([key, child]) => walk(child, [...path, key]));
  };
  walk(value, []);
};
const officeCreateBase = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('docx'), path, title: z.string().max(200), paragraphs: z.array(z.string().max(12000)).min(1).max(500) }).strict(),
  z.object({ kind: z.literal('xlsx'), path, sheets: z.array(z.object({ name: z.string().min(1).max(31).regex(/^[^\\/?*[\]:]+$/), headers: z.array(z.string().max(200)).min(1).max(32), rows: z.array(z.array(cell).max(32)).max(5000) }).strict()).min(1).max(10) }).strict(),
  z.object({ kind: z.literal('pptx'), path, title: z.string().max(200), slides: z.array(z.object({ title: z.string().max(150), bullets: z.array(z.string().max(300)).max(8), notes: z.string().max(20000).optional() }).strict()).min(1).max(50) }).strict(),
]);
export const officeCreate = officeCreateBase.superRefine(rejectInvalidXmlControls);
// Expose common top-level properties to model providers. Keep the discriminated
// union above as the authoritative validator before approval or any file I/O.
export const officeCreateInput = z.object({
  kind: z.enum(['docx', 'xlsx', 'pptx']).describe('docx=Word, xlsx=Excel, pptx=PowerPoint'),
  path: path.describe('工作目录内的相对文件名，例如 AI学习指南.docx'),
  title: officeCreateBase.options[0].shape.title.optional().describe('Word 和 PPT 必填标题'),
  paragraphs: officeCreateBase.options[0].shape.paragraphs.optional().describe('Word 必填，完整正文段落字符串数组，须包含用户要求的小节标题，不能只写在清单中；段落中的换页符 \\f 转为 Word 原生分页'),
  sheets: officeCreateBase.options[1].shape.sheets.optional().describe('Excel 必填，工作表数组'),
  slides: officeCreateBase.options[2].shape.slides.optional().describe('PPT 必填，幻灯片数组'),
}).strict();
export const officeRead = z.object({ path, offset: z.number().int().min(0).default(0), max_chars: z.number().int().min(100).max(50000).default(20000) }).strict();
