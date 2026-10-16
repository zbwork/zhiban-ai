/** Visible OOXML text only. Input has already passed the bounded ZIP expansion check. */
import { SaxesParser, type SaxesTagNS } from 'saxes';
import { LocalError } from './ledger.js';

const word = new Set(['http://schemas.openxmlformats.org/wordprocessingml/2006/main', 'http://purl.oclc.org/ooxml/wordprocessingml/main']);
const drawing = new Set(['http://schemas.openxmlformats.org/drawingml/2006/main', 'http://purl.oclc.org/ooxml/drawingml/main']);
const sheet = new Set(['http://schemas.openxmlformats.org/spreadsheetml/2006/main', 'http://purl.oclc.org/ooxml/spreadsheetml/main']);
const invalid = () => new LocalError('local.deliverable_invalid');

function parse(bytes: Uint8Array, visit: (stack: SaxesTagNS[], text: string | null, closing: boolean) => void): void {
  const parser = new SaxesParser({ xmlns: true });
  const stack: SaxesTagNS[] = [];
  parser.on('doctype', () => { throw invalid(); });
  parser.on('error', () => { throw invalid(); });
  parser.on('opentag', (tag) => {
    if (stack.length >= 256) throw invalid();
    stack.push(tag); visit(stack, null, false);
  });
  parser.on('text', (text) => visit(stack, text, false));
  parser.on('cdata', (text) => visit(stack, text, false));
  parser.on('closetag', () => { visit(stack, null, true); stack.pop(); });
  parser.write(new TextDecoder('utf-8', { fatal: true }).decode(bytes)).close();
}

export function extractOfficeText(ext: string, files: Record<string, Uint8Array>): string {
  let length = 0;
  const parts: string[] = [];
  const append = (text: string) => {
    length += Buffer.byteLength(text);
    if (length > 32 * 1024 * 1024) throw new LocalError('local.deliverable_size_limit');
    parts.push(text);
  };
  if (ext === '.docx' || ext === '.pptx') {
    const ns = ext === '.docx' ? word : drawing;
    const paths = ext === '.docx' ? ['word/document.xml'] : Object.keys(files).filter((path) => /^ppt\/slides\/slide\d+\.xml$/.test(path)).sort();
    for (const path of paths) {
      parse(files[path]!, (stack, text, closing) => {
        const tag = stack.at(-1)!;
        if (!tag || !ns.has(tag.uri)) return;
        if (text !== null && tag.local === 't') append(text);
        if (closing && ['p', 'br', 'tab'].includes(tag.local)) append('\n');
      });
      append('\n');
    }
  } else {
    const relationships = new Set<string>();
    const rels = files['xl/_rels/workbook.xml.rels'];
    if (rels) parse(rels, (stack, text, closing) => {
      const tag = stack.at(-1)!;
      if (!tag || tag.local !== 'Relationship' || text !== null || closing) return;
      const target = tag.attributes['Target']?.value ?? '';
      const path = target.startsWith('/xl/') ? target.slice(1) : `xl/${target}`;
      if (tag.attributes['TargetMode']?.value !== 'External' && tag.attributes['Type']?.value.endsWith('/worksheet')
        && /^xl\/worksheets\/sheet\d+\.xml$/.test(path) && files[path]) relationships.add(tag.attributes['Id']?.value ?? '');
    });
    if (files['xl/workbook.xml']) parse(files['xl/workbook.xml'], (stack, text, closing) => {
      const tag = stack.at(-1)!;
      if (!tag || !sheet.has(tag.uri) || tag.local !== 'sheet' || text !== null || closing) return;
      const id = Object.values(tag.attributes).find(attr => attr.local === 'id' && attr.uri.endsWith('/relationships'))?.value;
      if (id && relationships.has(id) && (!tag.attributes['state'] || tag.attributes['state'].value === 'visible')) append(`${tag.attributes['name']?.value ?? ''}\n`);
    });
    const shared: string[] = [];
    let value = '';
    if (files['xl/sharedStrings.xml']) parse(files['xl/sharedStrings.xml'], (stack, text, closing) => {
      const tag = stack.at(-1)!;
      if (!tag || !sheet.has(tag.uri)) return;
      if (tag.local === 'si') {
        if (closing) shared.push(value); else value = '';
      }
      if (text !== null && tag.local === 't' && !stack.some((node) => node.local === 'rPh')) value += text;
    });
    for (const path of Object.keys(files).filter((path) => /^xl\/worksheets\/sheet\d+\.xml$/.test(path)).sort()) {
      let cellType = '', cell = '', inCell = false;
      parse(files[path]!, (stack, text, closing) => {
        const tag = stack.at(-1)!;
        if (!tag || !sheet.has(tag.uri)) return;
        if (tag.local === 'c' && text === null) {
          if (!closing) {
            inCell = true; cell = ''; cellType = tag.attributes['t']?.value ?? '';
          } else {
            if (cellType === 's') {
              if (!/^\d+$/.test(cell) || shared[Number(cell)] === undefined) throw invalid();
              append(shared[Number(cell)]!);
            } else append(cell);
            append('\n'); inCell = false;
          }
        }
        if (inCell && text !== null && (tag.local === 'v' || (cellType === 'inlineStr' && tag.local === 't' && !stack.some((node) => node.local === 'rPh')))) cell += text;
      });
    }
  }
  return parts.join('');
}
