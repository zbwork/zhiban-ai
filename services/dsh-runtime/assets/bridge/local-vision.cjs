// Executed only in the read-only OS sandbox; all raster decoding stays in this child.
/* global __dirname */
const fs = require('node:fs');
const { Buffer } = require('node:buffer');
const path = require('node:path');
if (process.platform === 'win32') {
  // Bare package lookup probes the ungranted node_modules parent. Resolve only
  // these fixed decoder dependencies, without granting the entire runtime tree.
  const entries = new Map(require('./vision-dependencies.cjs').map(name => {
    const root = path.resolve(__dirname, '../../node_modules', name);
    const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
    return [name, path.resolve(root, pkg.main || 'index.js')];
  }));
  require('node:module').registerHooks({ resolve(specifier, context, nextResolve) {
    return nextResolve(entries.get(specifier) || specifier, context);
  } });
}
const { imageSize, disableFS } = require('image-size');
disableFS(true);
const { loadImage, createCanvas } = require('@napi-rs/canvas');
(async () => {
  const args = JSON.parse(fs.readFileSync(0, 'utf8'));
  let file = process.cwd();
  for (const part of args.path.split(/[\\/]/)) {
    file = path.join(file, part);
    if (fs.lstatSync(file).isSymbolicLink()) throw Error('link');
  }
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  let bytes;
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.nlink !== 1 || before.size > 1500000) throw Error('limit');
    bytes = fs.readFileSync(fd);
    const after = fs.fstatSync(fd);
    if (bytes.length !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs) throw Error('changed');
  } finally { fs.closeSync(fd); }
  const h = bytes.subarray(0, 12);
  let mimeType = h.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) ? 'image/png'
    : h[0] === 255 && h[1] === 216 && h[2] === 255 ? 'image/jpeg'
    : /^GIF8[79]a/.test(h.toString()) ? 'image/gif'
    : h.toString('ascii', 0, 4) === 'RIFF' && h.toString('ascii', 8, 12) === 'WEBP' ? 'image/webp' : null;
  if (!mimeType) throw Error('format');
  const dimensions = imageSize(bytes);
  if (!dimensions.width || !dimensions.height || dimensions.width * dimensions.height > 32000000) throw Error('dimensions');
  const image = await loadImage(bytes);
  const original_width = image.width, original_height = image.height;
  if (!original_width || !original_height || original_width * original_height > 32000000) throw Error('dimensions');
  let width = original_width, height = original_height, normalized = false;
  if (Math.min(width, height) < 256) {
    const scale = Math.min(256 / Math.min(width, height), 4096 / Math.max(width, height));
    const scaledWidth = Math.max(1, Math.round(width * scale)), scaledHeight = Math.max(1, Math.round(height * scale));
    width = Math.max(256, scaledWidth); height = Math.max(256, scaledHeight);
    const canvas = createCanvas(width, height), context = canvas.getContext('2d');
    context.fillStyle = '#ffffff'; context.fillRect(0, 0, width, height);
    context.imageSmoothingEnabled = scale < 1;
    context.drawImage(image, Math.floor((width-scaledWidth)/2), Math.floor((height-scaledHeight)/2), scaledWidth, scaledHeight);
    bytes = await canvas.encode('png'); mimeType = 'image/png'; normalized = true;
  }
  if (bytes.length > 1500000) throw Error('preview_limit');
  process.stdout.write(JSON.stringify({ data:bytes.toString('base64'), mimeType, original_width, original_height, width, height, normalized }));
})().catch(() => { process.exitCode = 2; });
