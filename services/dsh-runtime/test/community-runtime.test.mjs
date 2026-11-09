import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, mkdir, writeFile, readFile, realpath, rm, symlink } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';

const packageRoot = process.env.COMMUNITY_RUNTIME_TEST_ROOT;
assert.ok(packageRoot, 'COMMUNITY_RUNTIME_TEST_ROOT must name a built runtime');
const { communityModel, communityToolGuide } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/community.js')));
const { DesktopBroker } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/broker.js')));
const { readModelFailure } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/model-error.js')));
const { officeCreate, officeCreateInput } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/office-schema.js')));
const { z } = await import(pathToFileURL(join(packageRoot, 'node_modules/zod/index.js')));

test('broker normalizes only the default Responses tool choice before BYOK forwarding', async () => {
  const run = { task: { model: 'fixture', engine: 'codex_app_server' }, config: { protocol: 'openai-compatible' }, controller: new AbortController() };
  const seen = [];
  const broker = new DesktopBroker({
    supervisor: () => ({ authorize: () => run }), tools: [],
    model: async (_task, protocol, body) => {
      seen.push({ protocol, body });
      return new Response(JSON.stringify({ status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: 'OK' }] }] }), { headers: { 'content-type': 'application/json' } });
    },
  });
  const base = await broker.listen();
  try {
    for (const protocol of ['responses', 'chat/completions']) {
      for (const choice of [undefined, 'auto', 'none', 'required', { type: 'function', name: 'clock' }]) {
        const response = await fetch(base + '/llmgw/v1/by-key/' + protocol, {
          method: 'POST', headers: { authorization: 'Bearer scoped-key', 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'fixture', tool_choice: choice }),
        });
        assert.equal(response.status, 200);
        await response.text();
        assert.equal(seen.at(-1).protocol, protocol);
        assert.deepEqual(seen.at(-1).body.tool_choice, protocol === 'responses' && choice === 'auto' ? undefined : choice);
      }
    }
  } finally { await broker.close(); }
});

test('Responses final ID is inherited only from an unambiguous identity on this stream', async () => {
  const { normalizeResponsesTools } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/responses-tools.js')));
  const stream = events => new Response(events.map(e => 'data: ' + JSON.stringify(e) + '\n\n').join(''), {headers:{'content-type':'text/event-stream'}});
  const final = {type:'response.completed',response:{status:'completed',output:[]}};
  const created = id => ({type:'response.created',response:{id,status:'in_progress',output:[]}});
  const read = async events => (await normalizeResponsesTools(stream(events), undefined).text()).split('\n').filter(x=>x.startsWith('data:')).map(x=>JSON.parse(x.slice(5)));
  assert.equal((await read([created('resp_a'), final])).at(-1).response.id, 'resp_a');
  assert.equal((await read([final])).at(-1).response.id, undefined);
  assert.equal((await read([created('resp_a'),created('resp_b'),final])).at(-1).response.id, undefined);
  assert.equal((await read([created('resp_a'), {...final,response:{...final.response,id:'resp_existing'}}])).at(-1).response.id, 'resp_existing');
  assert.equal((await read([created('resp_a'), {...final,response:{...final.response,id:null}}])).at(-1).response.id, null);
});

test('community tool backup is derived from the actual registry without invented tools', () => {
  const tools = [{ name: 'list_files', description: 'list actual files', inputSchema: { type: 'object', properties: { path: { type: 'string' } } } }];
  const guide = communityToolGuide(tools);
  assert.ok(guide.includes('mcp__local__list_files'));
  assert.ok(guide.includes(JSON.stringify({ name: 'mcp__local__list_files', description: tools[0].description, parameters: tools[0].inputSchema })));
  assert.equal(guide.includes('search_files(scope=home)'), false);
  assert.equal(guide.includes('computer_capabilities'), false);
});

test('skill reference paths remain scoped with native separators and junctions', async () => {
  const { localTools } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/tools.js')));
  const root = await mkdtemp(join(tmpdir(), 'community-skill-path-'));
  const skills = join(root, 'skills');
  const skill = join(skills, 'test-skill');
  const outside = join(root, 'outside');
  await mkdir(join(skill, 'references'), { recursive: true }); await mkdir(outside);
  await writeFile(join(skill, 'references/data.txt'), 'scoped-reference');
  await writeFile(join(outside, 'secret.txt'), 'must-not-read');
  await symlink(outside, join(skill, 'outside'), process.platform === 'win32' ? 'junction' : 'dir');
  try {
    const tool = localTools({ privateRoot: root, artifacts: {}, brokerPort: 34567 }).find(tool => tool.name === 'read_skill_file');
    const run = { config: { skillsDir: skills } };
    const invoke = path => tool.call(run, { skill_code: 'test-skill', path }, new AbortController().signal);
    assert.equal((await invoke('references/data.txt')).text, 'scoped-reference');
    for (const path of ['../outside/secret.txt', 'references\\data.txt', join(outside, 'secret.txt'), 'outside/secret.txt']) {
      await assert.rejects(invoke(path), { code: 'local.invalid_path' });
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('office sheet schema uses portable bracket escaping and keeps host validation', () => {
  const schema = z.toJSONSchema(officeCreateInput);
  const pattern = schema.properties.sheets.items.properties.name.pattern;
  assert.ok(pattern.includes('\\['));
  const valid = { kind: 'xlsx', path: 'report.xlsx', sheets: [{ name: '收入 2026', headers: ['value'], rows: [['text', 1, true, null]] }] };
  assert.equal(officeCreate.safeParse(valid).success, true);
  for (const char of ['[', ']', ':', '*', '?', '/', '\\']) {
    const input = structuredClone(valid); input.sheets[0].name += char;
    assert.equal(officeCreate.safeParse(input).success, false, char);
    assert.equal(new RegExp(pattern).test(input.sheets[0].name), false, char);
  }
});

test('direct provider errors preserve HTTP categories without leaking raw error fields', async () => {
  let status = 400, message = 'WorkBuddy AI: invalid function call parameters SECRET';
  let errorCode = '';
  const server = createServer((_req, res) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message, code: errorCode } })); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    for (const [http, detail, providerCode, code] of [
      [400, message, '', 'model.tools_invalid'],
      [401, 'SECRET bad key', '', 'model.authentication_failed'],
      [429, 'SECRET too many', '', 'model.rate_limited'],
      [429, 'SECRET', 'insufficient_quota', 'model.upstream_quota'],
      [500, 'SECRET stack trace', '', 'model.upstream_failure'],
    ]) {
      status = http; message = detail; errorCode = providerCode;
      const response = await communityModel({ baseURL: 'http://127.0.0.1:' + server.address().port, apiKey: 'test-key', headers: {}, protocol: 'openai-compatible' }, { model: 'test' }, 'chat/completions', { model: 'test' }, AbortSignal.timeout(5000));
      const failure = await readModelFailure(response, AbortSignal.timeout(5000));
      assert.equal(failure.code, code);
      assert.ok(failure.message.includes('HTTP ' + http));
      assert.equal(JSON.stringify(failure).includes('SECRET'), false);
    }
  } finally { server.closeAllConnections(); server.close(); }
});

test('observed gateway rejection retries identical bytes once, without replaying tools', async () => {
  const original = globalThis.fetch;
  const route = { baseURL: 'https://api.airick.cn/v1', apiKey: 'test-only', headers: {}, protocol: 'openai-compatible' };
  const body = { model: 'test', messages: [{ role: 'tool', tool_call_id: 'done', content: 'already executed' }] };
  const rejected = (message = 'Request body format invalid', code = 'bad_response_status_code') => new Response(JSON.stringify({ error: { code, message } }), { status: 400 });
  try {
    for (const message of ['Request body format invalid', 'WorkBuddy AI: invalid function call parameters']) {
      const sent = [];
      const diagnostics = [];
      globalThis.fetch = async (_url, init) => { sent.push(init.body); return sent.length === 1 ? rejected(message) : new Response('success'); };
      const response = await communityModel(route, { model: 'test' }, 'chat/completions', body, AbortSignal.timeout(5000), async event => { diagnostics.push(event); });
      assert.equal(await response.text(), 'success');
      assert.deepEqual(sent, [JSON.stringify(body), JSON.stringify(body)]);
      assert.deepEqual(diagnostics.map(d => [d.attempt, d.status]), [[1, 400], [2, 200]]);
      assert.equal(diagnostics[0].request, diagnostics[1].request);
      assert.equal(JSON.stringify(diagnostics).includes('already executed'), false);
      assert.equal(JSON.stringify(diagnostics).includes('test-only'), false);
    }
    let calls = 0;
    globalThis.fetch = async () => { calls++; return rejected(); };
    const response = await communityModel(route, { model: 'test' }, 'chat/completions', body, AbortSignal.timeout(5000));
    assert.equal(response.status, 400); assert.equal(calls, 2);
    for (const [destination, message, code] of [
      ['https://api.airick.cn/v1', 'invalid tools schema', 'invalid_request_error'],
      ['https://example.com/v1', 'Request body format invalid', 'bad_response_status_code'],
    ]) {
      calls = 0; globalThis.fetch = async () => { calls++; return rejected(message, code); };
      await communityModel({ ...route, baseURL: destination }, { model: 'test' }, 'chat/completions', body, AbortSignal.timeout(5000));
      assert.equal(calls, 1);
    }
    calls = 0; const controller = new AbortController();
    globalThis.fetch = async () => { calls++; controller.abort(); return rejected(); };
    await assert.rejects(communityModel(route, { model: 'test' }, 'chat/completions', body, controller.signal));
    assert.equal(calls, 1);
    calls = 0; globalThis.fetch = async () => { calls++; return new Response('stream'); };
    const success = await communityModel(route, { model: 'test' }, 'chat/completions', body, AbortSignal.timeout(5000));
    assert.equal(await success.text(), 'stream'); assert.equal(calls, 1);
  } finally { globalThis.fetch = original; }
});

test('model proxy rejects redirects, nonlocal HTTP, model mismatch and protocol mismatch', async () => {
  const task = { model: 'test-model' };
  const signal = AbortSignal.timeout(5000);
  const route = { baseURL: 'http://example.com', apiKey: 'test-only-key', headers: {}, protocol: 'openai-compatible' };
  await assert.rejects(communityModel(route, task, 'chat/completions', { model: task.model }, signal));
  route.baseURL = 'https://example.com';
  await assert.rejects(communityModel(route, task, 'chat/completions', { model: 'other' }, signal));
  await assert.rejects(communityModel(route, task, 'messages', { model: task.model }, signal));
  let leaked = false;
  const server = createServer((req, res) => {
    if (req.url === '/leak') { leaked = true; res.end('{}'); }
    else { res.writeHead(302, { location: '/leak' }); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    route.baseURL = 'http://127.0.0.1:' + server.address().port;
    await assert.rejects(communityModel(route, task, 'chat/completions', { model: task.model }, signal));
    assert.equal(leaked, false);
  } finally { server.closeAllConnections(); server.close(); }
});

for (const mode of ['allow', 'legacy-official', 'deny', 'cancel', 'codex', 'codex-missing-response-id', 'codex-home-parent', 'ask', 'full', 'full-unconfirmed', 'codex-ask', 'codex-full']) test('real engine file/shell policy: ' + mode, { timeout: 120000 }, async () => {
  // Exercise user-profile ancestry without reading or changing real config.
  const root = await realpath(await mkdtemp(join(mode === 'codex-home-parent' ? homedir() : tmpdir(), 'community-runtime-test-')));
  let calls = 0;
  const run = randomUUID(), employee = randomUUID();
  const stateRoot = join(root, 'community-runtime', mode === 'legacy-official' ? 'official-' + randomUUID() : employee);
  const customWorkspace = join(root, 'user-selected-workspace');
  await mkdir(customWorkspace);
  const skillsDir = join(stateRoot, 'skills', randomUUID());
  await mkdir(join(skillsDir, 'community-verification', 'references'), { recursive: true });
  await writeFile(join(skillsDir, 'community-verification', 'SKILL.md'), '---\nname: community-verification\ndescription: COMMUNITY_SKILL_RESOURCE_CHECK\n---\nUse references/data.txt.');
  await writeFile(join(skillsDir, 'community-verification', 'references/data.txt'), 'full-package-resource');
  const attachmentRoot = join(root, 'community_attachments', employee);
  await mkdir(attachmentRoot, { recursive: true });
  const attachmentPath = join(attachmentRoot, 'input.txt');
  await writeFile(attachmentPath, 'original-attachment-bytes');
  const attachment = { name: 'input.txt', path: attachmentPath, size: 25, sha256: createHash('sha256').update('original-attachment-bytes').digest('hex') };
  let importedFile;
  const server = createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks));
    assert.equal(req.headers.authorization, 'Bearer test-only-key');
    assert.equal(req.url, mode.startsWith('codex') ? '/v1/responses' : '/v1/chat/completions');
    assert.equal(body.model, 'test-model');
    if (!importedFile) {
      const serialized = JSON.stringify(body);
      assert.ok(serialized.includes('本轮实际工具目录'));
      assert.equal(serialized.includes('search_files(scope=home)'), false);
      assert.equal(serialized.includes('computer_capabilities'), false);
      importedFile = serialized.match(/attachments-[^\/\\"]+\/1-input.txt/)?.[0];
      assert.ok(importedFile, 'model receives relative original attachment path');
    }
    const steps = [
      ['list_files', { path: importedFile }],
      ['read_file', { path: 'missing-probe.txt' }],
      ['read_file', { path: importedFile.split('/')[0] }],
      ['read_file', { path: importedFile }],
      ['read_skill_file', { skill_code: 'community-verification', path: 'references/data.txt' }],
      ['declare_deliverables', { files: [{ name: 'hello.txt', mime: 'text/plain', text_contains: ['community-ok'] }] }],
      ['write_file', { path: 'hello.txt', text: 'community-ok' }],
      ['read_file', { path: 'hello.txt' }],
      ['local_shell', { command: process.platform === 'win32' ? `[IO.File]::WriteAllText('shell-result.txt','shell-ok'); Write-Output 'shell-ok'` : 'printf shell-ok > shell-result.txt; printf shell-ok', timeout_ms: 10000 }],
    ];
    const step = steps[calls++];
    if (mode.startsWith('codex')) {
      assert.notEqual(body.tool_choice, 'auto');
      const namespace = (body.tools ?? []).find(tool => tool.type === 'namespace' && tool.tools?.some(child => child.name === step?.[0]));
      const name = namespace ? step?.[0] : (body.tools ?? []).find(tool => tool.name?.endsWith(step?.[0]))?.name ?? 'mcp__local__' + step?.[0];
      const item = step ? { type: 'function_call', id: 'fc_' + calls, call_id: 'call-' + calls, name, ...(namespace ? { namespace: namespace.name } : {}), arguments: JSON.stringify(step[1]), status: 'completed' } : { type: 'message', id: 'msg_' + calls, role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: '本机验证完成', annotations: [] }] };
      const response = { id: 'resp_' + calls, object: 'response', status: 'completed', model: 'test-model', output: [item], usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20 } };
      const events = [ ['response.created', { response: { ...response, status: 'in_progress', output: [] } }], ['response.output_item.added', { output_index: 0, item: step ? { ...item, arguments: '' } : item }],
        ...(step ? [['response.function_call_arguments.delta', { item_id: item.id, output_index: 0, delta: item.arguments }], ['response.function_call_arguments.done', { item_id: item.id, output_index: 0, arguments: item.arguments }]] : []),
        ['response.output_item.done', { output_index: 0, item }], ['response.completed', { response: mode === 'codex-missing-response-id' && calls === 1 ? Object.fromEntries(Object.entries(response).filter(([key]) => key !== 'id')) : response }] ];
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.end(events.map(([type, data], sequence_number) => 'event: ' + type + '\ndata: ' + JSON.stringify({ type, sequence_number, ...data }) + '\n\n').join(''));
      return;
    }
    const delta = step ? { tool_calls: [{ index: 0, id: 'call-' + calls, type: 'function', function: { name: 'mcp__local__' + step[0], arguments: JSON.stringify(step[1]) } }] } : { content: '本机验证完成' };
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.end('data: ' + JSON.stringify({ id: 'test', object: 'chat.completion.chunk', choices: [{ index: 0, delta, finish_reason: null }] }) + '\n\ndata: ' + JSON.stringify({ id: 'test', choices: [{ index: 0, delta: {}, finish_reason: step ? 'tool_calls' : 'stop' }] }) + '\n\ndata: [DONE]\n\n');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const child = spawn(process.execPath, [join(packageRoot, 'dist/desktop/community.js')], { env: { ...Object.fromEntries(['HOME', 'USERPROFILE', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA'].filter(key => process.env[key] !== undefined).map(key => [key, process.env[key]])), ...(process.platform === 'win32' ? { HOME: root, USERPROFILE: root, APPDATA: join(root, 'AppData/Roaming'), LOCALAPPDATA: join(root, 'AppData/Local') } : {}), LANG: 'en_US.UTF-8' }, stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  const events = []; let workspace; let broker; let key; let approved = false;
  const send = value => child.stdin.write(JSON.stringify(value) + '\n');
  const done = new Promise((resolve, reject) => {
    child.once('exit', code => reject(new Error('helper exited ' + code)));
    child.stderr.resume();
    lines.on('line', async line => {
      try {
      const event = JSON.parse(line); events.push(event);
      if (event.type === 'ready') {
        broker = event.url; key = event.key;
        let confirmation;
        if (mode === 'full' || mode === 'codex-full') {
          const proof = await fetch(broker + '/app/workspaces/full-confirmation', { method: 'POST', headers: { authorization: 'Bearer ' + key, 'content-type': 'application/json' }, body: JSON.stringify({ conversation: employee }) });
          confirmation = (await proof.json()).id;
        }
        send({ type: 'submit', mode: mode.endsWith('ask') ? 'ask' : mode.startsWith('full') || mode === 'codex-full' ? 'full' : 'assist', ...(confirmation ? { confirmation } : {}), id: run, employee, name: 'test', messageId: randomUUID(), workspace: customWorkspace, engine: mode.startsWith('codex') ? 'codex_app_server' : 'dsh', model: 'test-model', message: 'Write hello.txt, read it and run a shell command. This is an integration test.' + (mode === 'allow' ? ' '.repeat(120000) : ''), persona: 'Use tools.', skillsDir, attachments: [attachment], history: '[]', route: { baseURL: 'http://127.0.0.1:' + server.address().port, apiKey: 'test-only-key', headers: {}, protocol: 'openai-compatible' } });
      }
      if (event.type === 'accepted') workspace = event.workspace;
      if (event.type === 'approval') {
        approved = true;
        const path = mode === 'cancel' ? '/app/runs/' + run + '/cancel' : '/app/runs/' + run + '/approvals/' + event.id;
        fetch(broker + path, { method: 'POST', headers: { authorization: 'Bearer ' + key, 'content-type': 'application/json' }, body: JSON.stringify(mode === 'cancel' ? { fence: 1 } : { revision: event.revision, approved: ['allow', 'legacy-official', 'codex', 'codex-missing-response-id', 'codex-home-parent', 'ask', 'full', 'codex-ask', 'codex-full'].includes(mode), scope: 'once' }) }).catch(reject);
      }
      if (event.type === 'error') { if (mode === 'full-unconfirmed') resolve(event); else reject(new Error(event.code)); }
      if (event.type === 'result') resolve(event);
      } catch (error) { reject(error); }
    });
  });
  try {
    send({ type: 'initialize', privateRoot: stateRoot, documentsRoot: join(root, 'documents') });
    const result = await Promise.race([done, new Promise((_, reject) => setTimeout(() => reject(new Error('runtime timeout: ' + JSON.stringify(events.slice(-5)))), 100000).unref())]);
    if (mode === 'full-unconfirmed') {
      assert.equal(result.code, 'local.full_confirmation_required');
      assert.equal(calls, 0);
      await assert.rejects(readFile(join(customWorkspace, 'hello.txt')));
      return;
    }
    assert.equal(result.frame.event, mode === 'cancel' ? 'message.cancelled' : 'message.completed', JSON.stringify(result));
    assert.equal(workspace, customWorkspace);
    const preferences = JSON.parse(await readFile(join(stateRoot, 'workspaces.json'), 'utf8'));
    assert.equal(preferences.choices[0].workspace, customWorkspace);
    assert.equal(await readFile(join(workspace, 'hello.txt'), 'utf8').catch(e => { throw new Error(e.message + '\nEvents: ' + JSON.stringify(events)); }), 'community-ok');
    const toolResults = events.filter(e => e.frame?.event === 'message.tool_result');
    assert.ok(toolResults.some(e => e.frame.data.tool_status === 'failed' && String(e.frame.data.tool_result).includes('该路径是文件而非目录')));
    assert.ok(toolResults.some(e => e.frame.data.tool_status === 'failed' && String(e.frame.data.tool_result).includes('文件或目录不存在')));
    assert.ok(toolResults.some(e => e.frame.data.tool_status === 'failed' && String(e.frame.data.tool_result).includes('不是可读取的普通文件')));
    assert.ok(toolResults.some(e => String(e.frame.data.tool_result).includes('original-attachment-bytes')),
      'real engine reads imported original file');
    assert.ok(toolResults.some(e => String(e.frame.data.tool_result).includes('community-ok')), JSON.stringify(toolResults));
    if (['allow', 'legacy-official', 'codex', 'codex-missing-response-id', 'codex-home-parent', 'ask', 'full', 'codex-ask', 'codex-full'].includes(mode)) {
      assert.ok(toolResults.some(e => String(e.frame.data.tool_result).includes('shell-ok')), JSON.stringify(toolResults));
      assert.equal(await readFile(join(workspace, 'shell-result.txt'), 'utf8'), 'shell-ok');
    } else {
      await assert.rejects(readFile(join(workspace, 'shell-result.txt')));
    }
    assert.equal(approved, !['full', 'codex-full'].includes(mode));
    const approvals = events.filter(e => e.type === 'approval');
    assert.equal(approvals.some(e => e.intent.tool === 'write_file'), mode.endsWith('ask'));
    assert.equal(preferences.choices[0].mode, mode.endsWith('ask') ? 'ask' : 'assist');
    assert.ok(toolResults.some(e => String(e.frame.data.tool_result).includes('full-package-resource')),
      'real engine reads installed package resources through the scoped skill tool');
    if (mode !== 'cancel') {
      assert.equal(result.files.length, 1);
      assert.equal(await readFile(result.files[0].path, 'utf8'), 'community-ok');
    }
  } finally {
    child.stdin.end();
    await Promise.race([new Promise(resolve => child.once('exit', resolve)), new Promise(resolve => setTimeout(() => { child.kill(); resolve(); }, 10000).unref())]);
    server.closeAllConnections(); server.close(); await rm(root, { recursive: true, force: true, maxRetries: 3 });
  }
});


test('full access still requires one-time upload approval', async () => {
  const { LocalPolicy } = await import(pathToFileURL(join(packageRoot, 'dist/desktop/policy.js')));
  let pending;
  const policy = new LocalPolicy(randomUUID(), request => { pending = request; });
  const confirmation = policy.requestFull(); policy.setMode('full', confirmation.id);
  let executed = false;
  const result = policy.execute({ tool: 'upload_file', operation: 'upload', args: { artifact: 'immutable-id' } }, async () => { executed = true; });
  assert.ok(pending);
  assert.equal(executed, false);
  policy.approve(pending.id, pending.revision, false, 'once');
  await assert.rejects(result, error => error.code === 'local.approval_denied');
  assert.equal(executed, false);
});
