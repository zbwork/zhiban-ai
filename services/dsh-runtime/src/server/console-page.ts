/**
 * 开发测试台（dev only，GET / 返回）。同源调用 /zap/v1/*，用 fetch 读 SSE 逐帧渲染。
 * **不是产品界面**——它像 Bus 一样以 ZAP 客户端身份说话，纯粹方便本地/联调时用眼睛看效果。
 * 生产不开（config.devConsole=false 时本路由不注册）。
 */
export const CONSOLE_HTML = String.raw`<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>dsh-runtime 测试台</title>
<style>
  :root {
    --bg:#0e1116; --panel:#161b22; --panel2:#1c2230; --line:#2a313c; --fg:#e6edf3; --mut:#8b98a8;
    --acc:#5b9dff; --ok:#3fb984; --warn:#e3b341; --err:#f2666b; --tool:#a98bff;
  }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",PingFang SC,Microsoft YaHei,sans-serif; background:var(--bg); color:var(--fg); }
  header { display:flex; align-items:center; gap:12px; padding:10px 16px; border-bottom:1px solid var(--line); background:var(--panel); position:sticky; top:0; z-index:5; }
  header b { font-size:15px; } header .tag { font-size:11px; color:var(--mut); border:1px solid var(--line); border-radius:6px; padding:1px 7px; }
  header .sp { flex:1; } header .dot { width:8px;height:8px;border-radius:50%;background:var(--mut); }
  header .dot.on { background:var(--ok); } header .dot.off { background:var(--err); }
  .wrap { display:grid; grid-template-columns:320px 1fr; height:calc(100vh - 47px); }
  aside { border-right:1px solid var(--line); background:var(--panel); overflow-y:auto; padding:14px; }
  main { display:flex; flex-direction:column; min-width:0; }
  h3 { font-size:12px; text-transform:uppercase; letter-spacing:.05em; color:var(--mut); margin:18px 0 8px; }
  h3:first-child { margin-top:0; }
  label { display:block; font-size:12px; color:var(--mut); margin:8px 0 3px; }
  input, textarea, select { width:100%; background:var(--panel2); border:1px solid var(--line); color:var(--fg); border-radius:8px; padding:8px 10px; font:inherit; }
  textarea { resize:vertical; }
  button { background:var(--acc); color:#fff; border:0; border-radius:8px; padding:8px 12px; font:inherit; cursor:pointer; font-weight:600; }
  button.ghost { background:transparent; border:1px solid var(--line); color:var(--fg); font-weight:500; }
  button.danger { background:var(--err); } button:disabled { opacity:.45; cursor:not-allowed; }
  .row { display:flex; gap:8px; } .row > * { flex:1; }
  .agent { padding:8px 10px; border:1px solid var(--line); border-radius:8px; margin-bottom:6px; cursor:pointer; display:flex; justify-content:space-between; align-items:center; gap:8px; }
  .agent:hover { border-color:var(--acc); } .agent.sel { border-color:var(--acc); background:#17203050; }
  .agent .k { font-weight:600; } .agent .m { font-size:11px; color:var(--mut); }
  .agent .x { color:var(--mut); font-size:16px; line-height:1; padding:0 4px; }
  .meta { font-size:11px; color:var(--mut); word-break:break-all; }
  #log { flex:1; overflow-y:auto; padding:18px 22px; }
  .msg { max-width:820px; margin:0 auto 18px; }
  .msg .who { font-size:11px; color:var(--mut); margin-bottom:5px; }
  .bubble.user { background:var(--panel2); border:1px solid var(--line); border-radius:10px; padding:10px 13px; white-space:pre-wrap; }
  .bubble.ai { white-space:pre-wrap; }
  .reason { border-left:2px solid var(--line); color:var(--mut); font-size:13px; white-space:pre-wrap; margin:0 0 8px; padding:2px 0 2px 10px; max-height:120px; overflow:auto; }
  .reason summary { cursor:pointer; color:var(--mut); font-size:12px; }
  .tool { border:1px solid var(--line); border-left:3px solid var(--tool); border-radius:8px; margin:8px 0; overflow:hidden; }
  .tool .h { background:#1a2130; padding:6px 10px; font-size:12px; display:flex; gap:8px; align-items:center; }
  .tool .h .n { color:var(--tool); font-weight:600; } .tool .st { font-size:11px; color:var(--mut); margin-left:auto; }
  .tool .st.ok { color:var(--ok); } .tool .st.err { color:var(--err); }
  .tool pre { margin:0; padding:8px 10px; font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; white-space:pre-wrap; word-break:break-all; color:var(--mut); border-top:1px solid var(--line); max-height:220px; overflow:auto; }
  .foot { font-size:11px; color:var(--mut); margin-top:6px; }
  .foot.err { color:var(--err); } .foot.cx { color:var(--warn); }
  .composer { border-top:1px solid var(--line); padding:12px 22px; background:var(--panel); }
  .composer .row { max-width:820px; margin:0 auto; align-items:flex-end; }
  .composer textarea { flex:1; } .composer .row > button { flex:0 0 auto; }
  .empty { color:var(--mut); text-align:center; margin-top:60px; }
  code { background:#0b0f14; padding:1px 5px; border-radius:4px; font:12px ui-monospace,monospace; }
</style>
</head>
<body>
<header>
  <b>dsh-runtime</b><span class="tag">开发测试台</span>
  <span class="dot" id="dot"></span><span class="meta" id="hstat">连接中…</span>
  <span class="sp"></span>
  <span class="meta" id="sessmeta">未建会话</span>
</header>
<div class="wrap">
  <aside>
    <h3>连接</h3>
    <label>API Key（Bearer）</label>
    <input id="key" placeholder="dev-key" />
    <button class="ghost" style="width:100%;margin-top:8px" onclick="refresh()">刷新员工列表</button>

    <h3>新建员工</h3>
    <label>agent_key</label><input id="nk" placeholder="test-emp" />
    <label>名称</label><input id="nn" placeholder="测试员工" />
    <label>人设 system_prompt</label>
    <textarea id="np" rows="3" placeholder="你是知办测试数字员工，有 bash 和文件工具，需要时直接调用。回答简洁。"></textarea>
    <button style="width:100%;margin-top:8px" onclick="createAgent()">创建</button>

    <h3>员工</h3>
    <div id="agents"><div class="meta">加载中…</div></div>
  </aside>
  <main>
    <div id="log"><div class="empty">左侧选一个员工开始对话<br/>（没有就先新建一个）</div></div>
    <div class="composer">
      <div class="row">
        <textarea id="input" rows="2" placeholder="选中员工后，输入任务，回车发送（Shift+回车换行）…" onkeydown="onKey(event)"></textarea>
        <button id="send" onclick="send()" disabled>发送</button>
        <button id="cancel" class="danger" onclick="cancelTurn()" style="display:none">停止</button>
      </div>
    </div>
  </main>
</div>
<script>
const $ = (id) => document.getElementById(id);
const KEY_LS = 'dsh_console_key';
$('key').value = localStorage.getItem(KEY_LS) || 'dev-key';
$('key').addEventListener('change', () => { localStorage.setItem(KEY_LS, $('key').value); refresh(); });
let selected = null, sessionId = null, busy = false, curAbort = null;

function hdr(extra) { return Object.assign({ 'Authorization': 'Bearer ' + $('key').value, 'content-type': 'application/json' }, extra || {}); }
async function api(method, path, body) {
  const r = await fetch(path, { method, headers: hdr(), body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  if (!r.ok) throw new Error((j && j.error && j.error.code) ? j.error.code + ': ' + j.error.message : ('HTTP ' + r.status));
  return j;
}
async function health() {
  try { const j = await (await fetch('/healthz')).json(); $('dot').className = 'dot on'; $('hstat').textContent = 'v' + j.version + ' · 进程 ' + (j.pool ? j.pool.live + '/' + j.pool.max + (j.pool.queued ? ' · 排队 ' + j.pool.queued : '') : '?'); }
  catch { $('dot').className = 'dot off'; $('hstat').textContent = '不可达'; }
}
async function refresh() {
  try {
    const j = await api('GET', '/zap/v1/agents');
    const box = $('agents'); box.innerHTML = '';
    if (!j.agents.length) { box.innerHTML = '<div class="meta">还没有员工，先新建一个</div>'; return; }
    for (const a of j.agents) {
      const el = document.createElement('div');
      el.className = 'agent' + (a.agent_key === selected ? ' sel' : '');
      el.innerHTML = '<div><div class="k">' + esc(a.name || a.agent_key) + '</div><div class="m">' + esc(a.agent_key) + (a.model && a.model.primary ? ' · ' + esc(a.model.primary) : '') + '</div></div><span class="x" title="删除">✕</span>';
      el.onclick = (e) => { if (e.target.classList.contains('x')) { delAgent(a.agent_key); return; } pick(a.agent_key); };
      box.appendChild(el);
    }
  } catch (e) { $('agents').innerHTML = '<div class="foot err">' + esc(e.message) + '</div>'; }
}
async function createAgent() {
  const agent_key = $('nk').value.trim(); if (!agent_key) return alert('填 agent_key');
  try {
    await api('POST', '/zap/v1/agents', { agent_key, name: $('nn').value.trim() || agent_key, system_prompt: $('np').value.trim() });
    $('nk').value = ''; $('nn').value = ''; $('np').value = '';
    await refresh(); pick(agent_key);
  } catch (e) { alert('创建失败：' + e.message); }
}
async function delAgent(k) {
  if (!confirm('删除员工 ' + k + '？')) return;
  try { await api('DELETE', '/zap/v1/agents/' + encodeURIComponent(k)); if (selected === k) { selected = null; sessionId = null; $('send').disabled = true; $('sessmeta').textContent = '未建会话'; } await refresh(); } catch (e) { alert(e.message); }
}
async function pick(k) {
  selected = k; sessionId = null;
  document.querySelectorAll('.agent').forEach(el => el.classList.toggle('sel', el.querySelector('.m').textContent.startsWith(k)));
  $('log').innerHTML = '<div class="empty">已选 <code>' + esc(k) + '</code> —— 发一条消息，会自动建会话</div>';
  $('send').disabled = false; refresh();
}
async function ensureSession() {
  if (sessionId) return sessionId;
  const j = await api('POST', '/zap/v1/sessions', {
    agent_key: selected, agent: { agent_id: 'console', agent_key: selected },
    user: { tenant_id: 't-console', user_id: 'u-console' }, session_kind: 'single',
    conversation_context_hint: { tenant_id: 't-console', user_id: 'u-console', conversation_id: 'conv-console', purpose: 'production' }
  });
  sessionId = j.session_id; $('sessmeta').textContent = '会话 ' + sessionId; return sessionId;
}
function onKey(e) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } }

async function send() {
  if (busy || !selected) return;
  const text = $('input').value.trim(); if (!text) return;
  $('input').value = '';
  if ($('log').querySelector('.empty')) $('log').innerHTML = '';
  addUser(text);
  const ai = addAI();
  busy = true; $('send').disabled = true; $('cancel').style.display = '';
  try {
    const sid = await ensureSession();
    curAbort = new AbortController();
    const r = await fetch('/zap/v1/sessions/' + encodeURIComponent(sid) + '/messages', {
      method: 'POST', headers: hdr({ 'accept': 'text/event-stream' }), body: JSON.stringify({ role: 'user', text }), signal: curAbort.signal
    });
    if (!r.ok || !r.body) { const t = await r.text(); throw new Error(t || ('HTTP ' + r.status)); }
    await pump(r.body.getReader(), ai);
  } catch (e) {
    if (e.name === 'AbortError') ai.foot('已停止', 'cx'); else ai.foot('错误：' + e.message, 'err');
  } finally { busy = false; $('send').disabled = false; $('cancel').style.display = 'none'; curAbort = null; scroll(); }
}
async function cancelTurn() {
  if (curAbort) curAbort.abort();
  if (sessionId) { try { await api('POST', '/zap/v1/sessions/' + encodeURIComponent(sessionId) + '/cancel'); } catch {} sessionId = null; $('sessmeta').textContent = '会话已取消'; }
}
async function pump(reader, ai) {
  const dec = new TextDecoder(); let buf = '';
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) { handle(buf.slice(0, i), ai); buf = buf.slice(i + 2); }
  }
  if (buf.trim()) handle(buf, ai);
}
function handle(block, ai) {
  let ev = '', data = '';
  for (const line of block.split('\n')) {
    if (line.startsWith('event:')) ev = line.slice(6).trim();
    else if (line.startsWith('data:')) data += (data ? '\n' : '') + line.slice(5).replace(/^ /, '');
  }
  if (!ev) return;
  let d = {}; try { d = data ? JSON.parse(data) : {}; } catch {}
  if (ev === 'message.reasoning') ai.reason(d.reasoning || '');
  else if (ev === 'message.block.delta') ai.delta(d.block_index || 0, (d.block_delta && d.block_delta.text) || '');
  else if (ev === 'message.tool_call') ai.toolCall(d);
  else if (ev === 'message.tool_result') ai.toolResult(d);
  else if (ev === 'message.completed') ai.done(d.usage);
  else if (ev === 'message.failed') ai.foot('失败 ' + (d.error_code || '') + '：' + (d.error_message || ''), 'err');
  else if (ev === 'message.cancelled') { ai.foot('已取消', 'cx'); sessionId = null; $('sessmeta').textContent = '会话已取消'; }
  scroll();
}
function addUser(t) { const w = document.createElement('div'); w.className = 'msg'; w.innerHTML = '<div class="who">你</div><div class="bubble user"></div>'; w.querySelector('.bubble').textContent = t; $('log').appendChild(w); scroll(); }
function addAI() {
  const w = document.createElement('div'); w.className = 'msg';
  w.innerHTML = '<div class="who">员工 · ' + esc(selected) + '</div><details class="reason" style="display:none"><summary>思考中…</summary><div class="rtext"></div></details><div class="bubble ai"></div><div class="tools"></div><div class="foot" style="display:none"></div>';
  $('log').appendChild(w);
  const blocks = {}; let rbuf = '';
  const rEl = w.querySelector('.reason'), rText = w.querySelector('.rtext'), bub = w.querySelector('.bubble'), tools = w.querySelector('.tools'), foot = w.querySelector('.foot');
  const toolEls = {};
  return {
    reason(t) { rEl.style.display = ''; rbuf += t; rText.textContent = rbuf; rEl.querySelector('summary').textContent = '思考（' + rbuf.length + ' 字，点开）'; },
    delta(bi, t) { if (!blocks[bi]) { blocks[bi] = document.createElement('span'); bub.appendChild(blocks[bi]); } blocks[bi].textContent += t; },
    toolCall(d) {
      const el = document.createElement('div'); el.className = 'tool';
      el.innerHTML = '<div class="h">🔧 <span class="n">' + esc(d.tool_name || '') + '</span><span class="st">运行中…</span></div><pre class="args"></pre><pre class="res" style="display:none"></pre>';
      el.querySelector('.args').textContent = pretty(d.tool_args);
      tools.appendChild(el); toolEls[d.tool_call_id] = el;
    },
    toolResult(d) {
      const el = toolEls[d.tool_call_id]; if (!el) return;
      const ok = (d.tool_status || 'succeeded') === 'succeeded';
      const st = el.querySelector('.st'); st.textContent = ok ? '✓ 完成' : '✗ ' + (d.tool_status || '失败'); st.className = 'st ' + (ok ? 'ok' : 'err');
      const res = el.querySelector('.res'); res.style.display = ''; res.textContent = d.tool_result || '';
    },
    done(u) { rEl.open = false; if (u) { foot.style.display = ''; foot.textContent = 'usage: in ' + u.input_tokens + ' / out ' + u.output_tokens + ' / total ' + u.total_tokens + (u.model ? ' · ' + u.model : ''); } },
    foot(msg, cls) { foot.style.display = ''; foot.className = 'foot ' + (cls || ''); foot.textContent = msg; }
  };
}
function pretty(s) { try { return JSON.stringify(JSON.parse(s), null, 2); } catch { return s || ''; } }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
function scroll() { const l = $('log'); l.scrollTop = l.scrollHeight; }
health(); setInterval(health, 5000); refresh();
</script>
</body>
</html>`;
