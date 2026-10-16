import { build } from "esbuild";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
process.chdir(fileURLToPath(new URL(".", import.meta.url)));
const out = "../../assets/file_preview";
const result = await build({
  entryPoints: ["viewer.js"],
  bundle: true,
  write: false,
  minify: true,
  format: "iife",
  target: ["es2022"],
  legalComments: "inline",
  loader: { ".mjs": "js" },
});
const worker = await readFile(
  "node_modules/pdfjs-dist/build/pdf.worker.min.mjs",
  "utf8",
);
const shell = await readFile("viewer.html", "utf8");
const script = `window.pdfWorkerSource=${JSON.stringify(worker)};\n${result.outputFiles[0].text}`;
await mkdir(out, { recursive: true });
// Use a callback: replacement-string $&/$` sequences in libraries corrupt HTML.
const bootstrap = `(()=>{const script=document.createElement('script');script.textContent=new TextDecoder().decode(Uint8Array.from(atob('${Buffer.from(script).toString("base64")}'),c=>c.charCodeAt(0)));document.head.append(script);})();`;
await writeFile(
  `${out}/viewer.html`,
  shell.replace("/*BUNDLE*/", () => bootstrap),
);
await writeFile(
  `${out}/NOTICE.txt`,
  "Generated with npm ci && npm run build in scripts/file-preview.\n" +
    (await Promise.all(
      [
        "@aiden0z/pptx-renderer",
        "docx-preview",
        "exceljs",
        "pdfjs-dist",
        "marked",
        "dompurify",
        "highlight.js",
        "fflate",
      ].map(async (name) => {
        const pkg = JSON.parse(
          await readFile(`node_modules/${name}/package.json`, "utf8"),
        );
        let license = "";
        for (const f of [
          "LICENSE",
          "LICENSE.txt",
          "LICENSE.md",
          "LICENSE-MIT",
          "license",
        ]) {
          try {
            license = await readFile(`node_modules/${name}/${f}`, "utf8");
            break;
          } catch {}
        }
        // Preserve license text while normalizing upstream CRLF/trailing spaces.
        license = license.replace(/\r\n/g, "\n").replace(/[\t ]+$/gm, "");
        return `${name} ${pkg.version} (${pkg.license})\n${license}`;
      }),
    ).then((x) => x.join("\n\n"))),
);
console.log("Built local file preview assets");
