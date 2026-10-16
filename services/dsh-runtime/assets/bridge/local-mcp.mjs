// Official MCP stdio bridge. The worker receives only a run-scoped fake key in its environment.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { readFileSync } from 'node:fs';
import { URL } from 'node:url';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const endpoint = new URL(process.env.LOCAL_AGENT_BROKER_URL ?? 'http://invalid');
const key = process.env.LOCAL_AGENT_BROKER_KEY;
if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || !endpoint.port || !key) throw new Error('local broker bootstrap unavailable');
const server = new Server({ name: 'zhiban-local', version: '1.0.0' }, { capabilities: { tools: {} } });
const errors = JSON.parse(readFileSync(new URL('./local-tool-errors.json', import.meta.url), 'utf8'));
async function call(path, body) {
  const response = await fetch(new URL(path, endpoint), {
    method: 'POST', headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(420_000),
  });
  if (!response.ok) {
    const result = await response.json().catch(() => null);
    // Never return raw server errors, response bodies, credentials or paths.
    const message = errors[result?.error?.code];
    throw new Error(message ?? '本机工具调用未完成，原因未确认；不能据此断言用户拒绝批准或文件已生成。');
  }
  return response.json();
}
server.setRequestHandler(ListToolsRequestSchema, () => call('/worker/tools/list', {}));
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  try { return await call('/worker/tools/call', { name: request.params.name, arguments: request.params.arguments ?? {} }); }
  catch (error) {
    const safe = error instanceof Error && (Object.values(errors).includes(error.message) || error.message === '本机工具调用未完成，原因未确认；不能据此断言用户拒绝批准或文件已生成。');
    return { isError: true, content: [{ type: 'text', text: safe ? error.message : '本机工具连接中断或超时，未确认执行结果，请检查任务状态。' }] };
  }
});
await server.connect(new StdioServerTransport());
