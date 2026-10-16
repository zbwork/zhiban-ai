import { visibleResult } from './codex-visible-result.mjs';
/** Version-pinned adapter. The parent applies OS confinement to this entire tree. */
import { openCodexTransport } from './codex-transport.mjs';
import { startCodexBrokerRelay } from './codex-broker-relay.mjs';
let input = '';
for await (const chunk of process.stdin) { input += chunk; if (input.length > 1_000_000) process.exit(2); }
const turn = JSON.parse(input);
const relay = await startCodexBrokerRelay({ baseURL: process.env.LOCAL_AGENT_BROKER_URL });
const emit = (event, data) => process.stdout.write(JSON.stringify({ event, data: { message_id: turn.messageId, ...data } }) + '\n');
const conf = {
  model_provider: 'zhiban',
  'model_providers.zhiban.name': 'Zhiban local run',
  'model_providers.zhiban.base_url': relay.url + '/llmgw/v1/by-key',
  'model_providers.zhiban.wire_api': 'responses',
  'model_providers.zhiban.env_key': 'LOCAL_AGENT_BROKER_KEY',
  'model_providers.zhiban.request_max_retries': 0,
  'model_providers.zhiban.stream_max_retries': 0,
  'model_providers.zhiban.requires_openai_auth': false,
  'mcp_servers.local.url': relay.url + '/worker/mcp',
  'mcp_servers.local.bearer_token_env_var': 'LOCAL_AGENT_BROKER_KEY',
  'mcp_servers.local.tool_timeout_sec': 420,
  'mcp_servers.local.startup_timeout_sec': 30,
  'mcp_servers.local.required': true,
  web_search: 'disabled',
  check_for_update_on_startup: false,
};
const argv = [];
for (const [key, value] of Object.entries(conf)) argv.push('-c', `${key}=${JSON.stringify(value)}`);
const transport = await openCodexTransport(turn.binary, { cwd: turn.cwd, config: argv });
const child = transport.child;
const pending = new Map();
const tools = new Map();
const texts = new Map();
let next = 0, threadId, turnId, ended = false, usage, failureInfo;
const send = (message) => transport.send(message);
const request = (method, params) => new Promise((resolve, reject) => {
  const id = ++next; pending.set(id, {resolve,reject}); send({id,method,params});
});
const errorInfo = (error) => {
  const value=error?.codexErrorInfo;
  const allowed=new Set(['contextWindowExceeded','usageLimitExceeded','serverOverloaded','cyberPolicy','internalServerError','unauthorized','badRequest','threadRollbackFailed','sandboxError','other','httpConnectionFailed','responseStreamConnectionFailed','responseStreamDisconnected','responseTooManyFailedAttempts','activeTurnNotSteerable']);
  const key=typeof value==='string'?value:Object.keys(value??{})[0];
  const status=value?.[key]?.httpStatusCode;
  const message=String(error?.message??'').toLowerCase();
  const reason=message.includes('image')?'image_response':message.includes('tool')?'tool_response':message.includes('stream')?'stream_response':'unknown';
  const terms=['input_image','image_url','image','function_call_output','encrypted','reasoning','invalid_request','unsupported','parse','decrypt','verify','expected','array','string','missing','timeout','overloaded','rate limit','quota','400','401','403','429','500','502','503','stream disconnected'].filter(term=>message.includes(term));
  return {kind:allowed.has(key)?key:'other',terms,...(Number.isInteger(status)&&status>=100&&status<=599?{http_status:status}:{}),reason};
};
const finish = (kind, code = 'zap.local_execution_failed') => {
  if (ended) return;
  ended = true;
  for (const [id,name] of tools) emit('message.tool_result', {tool_call_id:id,tool_name:name,tool_status:'failed',tool_result:'工具调用已中断，结果未确认。'});
  const incomplete = tools.size > 0;
  tools.clear();
  if (kind === 'completed' && !incomplete) emit('message.completed', {role:'assistant',blocks:[...texts.values()].map(text=>({type:'markdown',text})), ...(usage ? {usage}: {})});
  else if (kind === 'interrupted') emit('message.cancelled', {...(usage ? {usage}: {})});
  else emit('message.failed', {error_code:code,error_message:'本机执行未完整结束，请检查已有结果。',...(usage ? {usage}: {}),...(failureInfo?{engine_error:failureInfo}:{})});
  transport.close();
};
const itemName = (item) => item.type === 'mcpToolCall' ? `mcp__${item.server}__${item.tool}` : `codex.${item.type}`;
const toolTypes = new Set(['mcpToolCall','commandExecution','fileChange','dynamicToolCall']);
const handle = (message) => {
  if (message.id !== undefined && !message.method) {
    const p=pending.get(message.id); pending.delete(message.id);
    if (message.error) p?.reject(new Error('app_server_request_failed')); else p?.resolve(message.result);
    return;
  }
  if (message.id !== undefined) {
    // User file operations are approved by the Broker, never by Codex session-wide grants.
    const method=message.method;
    if (method === 'item/commandExecution/requestApproval' || method === 'item/fileChange/requestApproval') send({id:message.id,result:{decision:'decline'}});
    else send({id:message.id,error:{code:-32601,message:'Use the authorized local tools'}});
    return;
  }
  const p=message.params ?? {};
  if (p.threadId && threadId && p.threadId!==threadId) return;
  if (p.turnId && turnId && p.turnId!==turnId) return;
  if (ended) return;
  if (message.method === 'item/agentMessage/delta') {
    const old=texts.get(p.itemId) ?? ''; texts.set(p.itemId,old+p.delta);
    emit('message.block.delta',{block_index:[...texts.keys()].indexOf(p.itemId),block_delta:{type:'markdown',text:p.delta}});
  } else if (message.method === 'item/reasoning/summaryTextDelta') emit('message.reasoning',{reasoning:p.delta});
  else if (message.method === 'item/started' && toolTypes.has(p.item?.type)) {
    const item=p.item, name=itemName(item); tools.set(item.id,name);
    emit('message.tool_call',{tool_call_id:item.id,tool_name:name,tool_status:'running',tool_args:JSON.stringify(item.arguments ?? item.command ?? item.changes ?? {})});
  } else if (message.method === 'item/completed') {
    const item=p.item ?? {};
    if (item.type === 'agentMessage') {
      const old=texts.get(item.id) ?? '';
      if (!old && item.text) {texts.set(item.id,item.text);emit('message.block.delta',{block_index:[...texts.keys()].indexOf(item.id),block_delta:{type:'markdown',text:item.text}});}
    }
    if (tools.has(item.id)) {
      const name=tools.get(item.id);tools.delete(item.id);
      const success=item.status==='completed' && !item.error && item.result?.isError!==true && (item.exitCode===undefined || item.exitCode===null || item.exitCode===0);
      emit('message.tool_result',{tool_call_id:item.id,tool_name:name,tool_status:success?'succeeded':'failed',tool_result:JSON.stringify(visibleResult(item.result) ?? item.error ?? {status:item.status,exitCode:item.exitCode}).slice(0,2000)});
    }
  } else if (message.method==='thread/tokenUsage/updated') {
    const u=p.tokenUsage?.total ?? p.tokenUsage?.last;
    if (u) { usage={input_tokens:u.inputTokens ?? 0,output_tokens:u.outputTokens ?? 0,total_tokens:u.totalTokens ?? 0,model:turn.model}; emit('local.usage',{usage}); }
  } else if (message.method==='error') failureInfo=errorInfo(p.error);
  else if (message.method==='turn/completed') { if(p.turn?.error)failureInfo=errorInfo(p.turn.error); finish(p.turn?.status); }
};
transport.events.on('message',message=>{try{handle(message);}catch{finish('failed');child.kill();}});
transport.events.on('invalid',()=>{finish('failed');child.kill();});
child.on('error',()=>finish('failed'));
child.on('exit',()=>{
  relay.close();
  if(!ended) finish('failed');
  for(const p of pending.values())p.reject(new Error('process_exit'));
  pending.clear();
});
try {
 await request('initialize',{clientInfo:{name:'zhiban_local',version:'1.0.0'}});
 send({method:'initialized',params:{}});
 // Configure only this ephemeral CODEX_HOME; the platform image tool owns its interface and billing.
 await request('skills/config/write',{name:'imagegen',enabled:false});
 const start=await request('thread/start',{model:turn.model,modelProvider:'zhiban',cwd:turn.cwd,approvalPolicy:'never',sandbox:'danger-full-access',ephemeral:true,baseInstructions:turn.instructions});
 threadId=start.thread.id;
 const result=await request('turn/start',{threadId,input:[{type:'text',text:turn.prompt}],model:turn.model});
 turnId=result.turn.id;
} catch { finish('failed');child.kill(); }
