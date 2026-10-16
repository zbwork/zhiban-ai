import { createHash } from 'node:crypto';
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { knowledgeContextPrefix, skillPrefix } from '../context/prompt.js';
import { attachmentFromBlock, attachmentsPrefix, safeFileName, type SavedAttachment } from '../files/attachments.js';
import { extractSkillPackage, parseSkillsNode, skillsFromSnapshot } from '../skills/skills.js';
import { downloadResource } from './download.js';
import { fingerprint, LocalError } from './ledger.js';
import type { ActiveLocalRun } from './supervisor.js';
import { writeWorkspaceBytes } from './workspace-files.js';

export interface LocalContextInput { blocks?: unknown; skills?: unknown; knowledge?: unknown; metadata?: Record<string, unknown> }
export class DesktopContext {
  constructor(private readonly opts: { privateRoot: string; skillsRoot: string; brokerPort: number; allowHttpStorage?: () => boolean; download?: typeof downloadResource }) {}

  /** Called only after durable server acceptance; URLs remain host-only and are discarded after use. */
  async prepare(run: ActiveLocalRun): Promise<void> {
    const input = run.config.context;
    if (!input) return;
    const signal = run.controller.signal;
    const download = this.opts.download ?? downloadResource;
    const saved: SavedAttachment[] = [];
    const blocks = Array.isArray(input.blocks) ? input.blocks : [];
    const attachments = blocks.filter((v): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)).map(attachmentFromBlock).filter((v) => v !== undefined);
    let downloaded = 0;
    for (const [index, file] of attachments.entries()) {
      signal.throwIfAborted();
      const name = safeFileName(file.name, `attachment-${index + 1}`);
      const path = `.attachments/${fingerprint(run.task.run)}/${index + 1}-${name}`;
      const meta = { type: file.type, name, mime: file.mime, file_id: file.file_id };
      try {
        if (index >= 16 || downloaded >= 128 * 1024 * 1024) throw new LocalError('local.attachment_limit');
        const max = Math.min(32 * 1024 * 1024, 128 * 1024 * 1024 - downloaded);
        if (file.size !== undefined && file.size > max) throw new LocalError('local.attachment_limit');
        await run.policy.execute({ tool: 'receive_attachment', operation: 'write', args: { name, path } }, async (permissionSignal) => {
          const bytes = await download(file.url, max, permissionSignal, { allowHttpStorage: this.opts.allowHttpStorage?.() });
          downloaded += bytes.length;
          await writeWorkspaceBytes(run.config.workspace, path, bytes, this.opts, permissionSignal);
          saved.push({ ...meta, path, size: bytes.length });
        }, signal);
      } catch { signal.throwIfAborted(); saved.push({ ...meta, error: '附件未下载或写入未获授权' }); }
    }
    const parsed = input.skills == null ? { snapshot: { agent_skills: [], builtin_skills: [] }, errors: [] } : parseSkillsNode(input.skills);
    if (parsed.errors.length || parsed.snapshot.agent_skills.length > 32) throw new LocalError('local.invalid_skills');
    const skills = skillsFromSnapshot(parsed.snapshot);
    const dir = join(this.opts.skillsRoot, fingerprint({ run: run.task.run, fence: run.task.fence }));
    await mkdir(dir, { recursive: true, mode: 0o700 });
    run.config.skillsDir = dir;
    const missing: string[] = [];
    let packagesSize = 0;
    let expandedSize = 0;
    for (const skill of [...skills.agent.values()]) {
      signal.throwIfAborted();
      try {
        if (packagesSize >= 64 * 1024 * 1024 || expandedSize >= 64 * 1024 * 1024) throw new LocalError('local.skill_limit');
        const bytes = await download(skill.package_url, Math.min(20 * 1024 * 1024, 64 * 1024 * 1024 - packagesSize), signal, { allowHttpStorage: this.opts.allowHttpStorage?.() });
        packagesSize += bytes.length;
        if (createHash('sha256').update(bytes).digest('hex') !== skill.package_sha256) throw new LocalError('local.skill_hash_mismatch');
        expandedSize += await extractSkillPackage(bytes, join(dir, skill.code), { signal, maxBytes: 64 * 1024 * 1024 - expandedSize });
      } catch { signal.throwIfAborted(); skills.agent.delete(skill.skill_id); missing.push(skill.code); }
    }
    const knowledge = typeof input.knowledge === 'object' && input.knowledge !== null && !Array.isArray(input.knowledge)
      ? { ...input.knowledge, suggest_tool_follow_up: false } : undefined;
    const catalog = [...skills.agent.values()].map((skill) => `- ${String(skill.frontmatter?.['name'] ?? skill.code)}：read_skill_file(${JSON.stringify({ skill_code: skill.code, path: 'SKILL.md' })})`).join('\n');
    run.config.prompt = (catalog ? `[可用关联技能]\n按任务需要读取技能说明，参考文件也用 read_skill_file 读取；技能 code 不等同于原生 skill 工具名称。\n${catalog}\n\n` : '') + attachmentsPrefix(saved) + skillPrefix({ skills }, input.metadata ?? {}, (code) => `请先调用 read_skill_file，参数 ${JSON.stringify({ skill_code: code, path: 'SKILL.md' })}，读取本轮已校验的技能说明`)
      + (missing.length ? `[未加载的技能] ${missing.join('、')}。如任务依赖这些技能，请告知用户，不能假装已加载。\n\n` : '')
      + knowledgeContextPrefix(run.task.message, { knowledge_context: knowledge });
    // A selected skill must never silently turn into a generic task.
    const selected = input.metadata?.['active_skill_uuid'];
    const selectedCode = input.metadata?.['active_skill_code'];
    if ((input.metadata?.['active_skill_kind'] ?? 'agent') === 'agent') {
      const unavailable = typeof selected === 'string' && selected.trim()
        ? !skills.agent.has(selected)
        : typeof selectedCode === 'string' && selectedCode.trim() && ![...skills.agent.values()].some((skill) => skill.code === selectedCode);
      if (unavailable) throw new LocalError('local.selected_skill_unavailable');
    }
    // The current Flutter composer sends skill blocks (and may select several),
    // while older clients use active_skill_* metadata. Validate both forms.
    const selectedCodes = [...new Set(blocks.filter((block): block is Record<string, unknown> =>
      typeof block === 'object' && block !== null && !Array.isArray(block) && (block as Record<string, unknown>)['type'] === 'skill')
      .map((block) => block['slug']).filter((code): code is string => typeof code === 'string' && code.trim().length > 0).map((code) => code.trim()))];
    for (const code of selectedCodes) {
      if (skills.builtin.some((skill) => skill.code === code)) continue;
      if (![...skills.agent.values()].some((skill) => skill.code === code)) throw new LocalError('local.selected_skill_unavailable');
      run.config.prompt += skillPrefix({ skills }, { active_skill_code: code }, (code) => `请先调用 read_skill_file，参数 ${JSON.stringify({ skill_code: code, path: 'SKILL.md' })}，读取本轮已校验的技能说明`);
    }
    run.config.context = undefined;
  }

  async release(run: ActiveLocalRun): Promise<void> {
    if (run.config.skillsDir) await rm(run.config.skillsDir, { recursive: true, force: true });
    run.config.context = undefined;
  }
}
