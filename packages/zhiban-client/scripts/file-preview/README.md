# Local file preview renderer

Run `npm ci && npm run build` here after source/dependency changes. The generated
`assets/file_preview/viewer.html` and `NOTICE.txt` ship with Flutter; no CDN or
online document conversion is used. Commit the asset, lockfile and source together.

Flutter downloads authorized bytes and invokes `window.previewFile` with base64,
format, name and theme. The renderer never receives tokens or signed URLs. HTML
runs in an opaque sandbox iframe; it has no native bridge. Office preview is read
only; XLSX uses cached formula results and does not provide a calculation engine.

`npm test` exercises real document renderers in Chromium (install browser with
`npx playwright install chromium` if needed). Fixtures are generated in memory.

Security checks: `npm audit --omit=dev --registry=https://registry.npmjs.org`.
DOMPurify and fflate are pinned to patched releases. ExcelJS currently depends on
uuid 8; its reported buffer-bound issue affects v3/v5/v6, whereas ExcelJS only
uses v4 without a caller-supplied buffer. Do not automatically downgrade ExcelJS
to address that transitive warning; re-evaluate when upgrading dependencies.
The fixture-only `pptxgenjs` dependency also reports `image-size` parser warnings;
tests generate text-only slides and never load external ICNS/JXL/HEIF inputs.
Neither package's test tooling is included in the shipped viewer bundle.
