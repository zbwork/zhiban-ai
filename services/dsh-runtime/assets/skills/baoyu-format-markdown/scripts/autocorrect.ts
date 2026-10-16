import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

// 优先走本地 node_modules/.bin/autocorrect-node（镜像 build 阶段已 bun install 好），
// 不走 `npx`。`npx` 在二进制不存在时会去 npm registry 拉一份缓存到 ~/.npm，违反
// "镜像 build 时备齐所有依赖、运行时不联网" 的约束。
// autocorrect-node 包名是 `autocorrect-node`，但 npm 在 .bin 里只生成短别名 `autocorrect`，
// 因为它的 package.json 把 bin 字段写的就是 `autocorrect`。
// 不能用 `autocorrect-node` 这个名字找 .bin。
const here = dirname(fileURLToPath(import.meta.url));
const localBin = join(here, "node_modules", ".bin",
  process.platform === "win32" ? "autocorrect.cmd" : "autocorrect");

export function applyAutocorrect(filePath: string): boolean {
  if (!existsSync(localBin)) {
    console.error(`[baoyu-format-markdown] autocorrect 二进制找不到：${localBin}`);
    console.error(`[baoyu-format-markdown] 检查 \`bun install\` 是否在 scripts/ 下跑过`);
    return false;
  }
  const result = spawnSync(localBin, ["--fix", filePath], { stdio: "inherit" });
  return result.status === 0;
}
