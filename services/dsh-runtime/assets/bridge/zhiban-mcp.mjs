#!/usr/bin/env node
// 知办平台工具的 MCP stdio 服务（由 dsh `mcp-client` 在 agent 进程里拉起）。
// 只做一件事：把 MCP tool call 转成对本 runtime 回环桥的 HTTP 调用（携带每会话的 X-Bridge-Key）。
// 纯 JS、随包发布、不依赖构建；凭据不在这里（见 src/backchannel/bus-client.ts）。
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const argv = process.argv.slice(2);
const arg = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const endpoint = arg('--endpoint');
const key = arg('--key');
if (!endpoint || !key) {
  process.stderr.write('zhiban-mcp: --endpoint and --key are required\n');
  process.exit(2);
}

// 图片生成可能要几分钟（gpt-image-2 ~4 分钟才回响应头），其它工具 90s
const TIMEOUT_MS = { image_generate: 420_000 };

async function bridge(tool, args) {
  const res = await fetch(`${endpoint}/${tool}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-bridge-key': key },
    body: JSON.stringify(args ?? {}),
    signal: AbortSignal.timeout(TIMEOUT_MS[tool] ?? 90_000),
  });
  let body = {};
  try {
    body = await res.json();
  } catch {
    body = {};
  }
  if (!res.ok || body.error) {
    const e = body.error ?? { code: `http_${res.status}`, message: 'platform tool call failed' };
    return { content: [{ type: 'text', text: `平台工具调用失败（${e.code}）：${e.message}` }], isError: true };
  }
  return { content: [{ type: 'text', text: JSON.stringify(body.result ?? null, null, 0) }] };
}

const server = new McpServer({ name: 'zhiban', version: '1.0.0' });

server.registerTool(
  'kb_search',
  {
    title: '知办知识库检索',
    description: '在当前数字员工已授权的知识库中检索。用于需要企业资料/制度/产品知识作答时。先把用户问题改写成精炼的检索词；不要编造未检索到的内容。',
    inputSchema: {
      query: z.string().min(1).describe('精炼的检索问题'),
      top_k: z.number().int().min(1).max(20).optional().describe('返回条数上限，普通问题 3~8'),
      continuation_token: z.string().optional().describe('上一次结果返回的续页 token'),
    },
  },
  (a) => bridge('kb_search', a),
);

server.registerTool(
  'memory_recall',
  {
    title: '回忆用户长期记忆',
    description: '召回当前用户/数字员工的长期记忆（偏好、既往决定、稳定事实）。涉及"上次/之前/我喜欢/记得吗"这类问题时使用。',
    inputSchema: {
      query: z.string().min(1).describe('要回忆的内容'),
      // 取值必须是平台真实 scope（Bus ScopeKind）；短名 user/agent/group 不是合法值，桥会兼容映射
      scopes: z
        .array(z.enum(['user_long_term', 'agent_private', 'session', 'group_shared']))
        .optional()
        .describe('限定召回范围：user_long_term 跨 agent 的本人长期记忆 / agent_private 本人在该员工下的 / session 当前会话 / group_shared 群共享；缺省用平台默认集'),
      limit: z.number().int().min(1).max(50).optional(),
    },
  },
  (a) => bridge('memory_recall', a),
);

server.registerTool(
  'memory_write',
  {
    title: '写入长期记忆',
    description: '把一条稳定的事实或偏好写入用户长期记忆（用户明确要求记住、或出现明确的长期偏好时）。不要写入临时信息。',
    inputSchema: {
      content: z.string().min(1).describe('要记住的一条稳定事实或偏好'),
      role: z.enum(['user', 'assistant']).optional().describe('内容来源角色，缺省 user'),
    },
  },
  (a) => bridge('memory_write', a),
);

server.registerTool(
  'a2a_discover',
  {
    title: '发现可协作的数字员工',
    description: '列出当前上下文下可以调用的其他数字员工。用户问"有哪些同事可以帮忙/能联系谁"或任务明显属于别的岗位时先用它；只能用返回的候选作答，不得凭常识编造名单。',
    inputSchema: {
      query: z.string().optional().describe('任务描述，用于候选排序'),
      tags: z.array(z.string()).optional(),
      mode: z.enum(['sync', 'async']).optional(),
      limit: z.number().int().min(1).max(50).optional(),
      cursor: z.string().optional(),
    },
  },
  (a) => bridge('a2a_discover', a),
);

server.registerTool(
  'a2a_invoke',
  {
    title: '把任务派给另一位数字员工',
    description: '调用 a2a_discover 返回的某位数字员工执行任务。user_text 必须是你为对方生成的清晰任务指令（只含业务事实、约束、期望输出），不要包含"帮我找/联系某某"之类路由话术，也不要传任何 id/token/endpoint。',
    inputSchema: {
      to_agent_id: z.string().min(1).describe('a2a_discover 返回的 agent_id'),
      user_text: z.string().min(1).describe('给对方的任务指令'),
      idempotency_key: z.string().optional().describe('同一任务重试时保持不变'),
    },
  },
  (a) => bridge('a2a_invoke', a),
);

server.registerTool(
  'a2a_get_edge',
  {
    title: '查询协作任务的当前状态/结果',
    description: '查询之前 a2a_invoke 派出去的任务（edge）当前状态与结果。任务未完成时会返回 pending/running，稍后可再查；已完成会带回 response_payload。',
    inputSchema: {
      edge_id: z.string().min(1).describe('a2a_invoke 返回的 edge_id'),
    },
  },
  (a) => bridge('a2a_get_edge', a),
);

server.registerTool(
  'a2a_cancel_edge',
  {
    title: '取消尚未完成的协作任务',
    description: '取消一个尚未完成的协作任务（edge）。已终态的任务无法取消；可传 reason 便于对方看到取消原因。',
    inputSchema: {
      edge_id: z.string().min(1).describe('a2a_invoke 返回的 edge_id'),
      reason: z.string().optional().describe('取消原因，简短一句'),
    },
  },
  (a) => bridge('a2a_cancel_edge', a),
);

server.registerTool(
  'image_generate',
  {
    title: '生成图片',
    description: '根据文字描述生成图片（公司网关 doubao/gemini/gpt 图像模型）。用户要配图、海报、插画、示意图时使用。生成的 PNG 会写到工作目录 outbox/images/ 并自动作为附件发给用户；回复里用 ![](<outbox/images/文件名>) 引用。中文长文本不要指望画进图里（会糊字），文字排版用 PPT/Markdown 做。',
    inputSchema: {
      prompt: z.string().min(1).describe('画面描述，具体、有主体/风格/构图'),
      size: z.string().regex(/^\d{3,4}x\d{3,4}$/).optional().describe('宽x高，如 1024x1024、1280x720；缺省 1024x1024'),
      model: z.string().optional().describe('缺省用平台配置的模型'),
      n: z.number().int().min(1).max(4).optional().describe('张数，缺省 1'),
    },
  },
  (a) => bridge('image_generate', a),
);

const transport = new StdioServerTransport();
await server.connect(transport);
