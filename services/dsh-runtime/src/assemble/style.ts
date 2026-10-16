/**
 * 平台默认输出风格（OpenClaw 的 `zhiban-output-style` 是 alwaysActive 技能；dsh 这边直接并入系统提示，所有会话生效）。
 * 正文来自 assets/skills/zhiban-output-style/SKILL.md（去掉 frontmatter），跟着 port-openclaw-skills.sh 一起更新。
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export function loadOutputStyle(platformSkillsDir: string): string {
  const file = join(platformSkillsDir, 'zhiban-output-style', 'SKILL.md');
  if (!existsSync(file)) return '';
  const raw = readFileSync(file, 'utf8');
  const body = raw.startsWith('---') ? raw.replace(/^---[\s\S]*?\n---\n?/, '') : raw;
  const text = body.trim();
  return text ? `【输出风格】\n${text}` : '';
}
