import { platform, release } from 'node:os';
import { z } from 'zod';
import type { DesktopTool } from './broker.js';

export function systemInfo(now = new Date()) {
  return {
    local_date: new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit' }).format(now),
    local_time: new Intl.DateTimeFormat('zh-CN', { dateStyle: 'full', timeStyle: 'long' }).format(now),
    time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    utc: now.toISOString(), platform: platform(), os_release: release(),
  };
}

export function systemTool(): DesktopTool {
  const schema = z.object({}).strict();
  return { name: 'system_info', description: '读取此刻本机系统日期、时间、时区和操作系统。问今天几月几号优先使用此工具，不需浏览器、联网或审批。',
    operation: 'read', schema, inputSchema: z.toJSONSchema(schema),
    call: async (_run, _args, signal) => { signal.throwIfAborted(); return systemInfo(); },
  };
}
