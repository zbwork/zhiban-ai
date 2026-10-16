/** Repair only unambiguous flattened names that were advertised on this request. */
export function normalizeResponsesTools(response: Response, tools: unknown): Response {
  if (!response.body || !response.headers.get('content-type')?.includes('text/event-stream') || !Array.isArray(tools)) return response;
  const aliases = new Map<string, { name: string; namespace: string } | null>();
  for (const tool of tools) {
    if (tool?.type !== 'namespace' || typeof tool.name !== 'string' || !Array.isArray(tool.tools)) continue;
    for (const child of tool.tools) {
      if (child?.type !== 'function' || typeof child.name !== 'string') continue;
      const key = `${tool.name}.${child.name}`;
      aliases.set(key, aliases.has(key) ? null : { namespace: tool.name, name: child.name });
    }
  }
  for (const tool of tools) if (typeof tool?.name === 'string' && tool.type !== 'namespace' && aliases.has(tool.name)) aliases.set(tool.name, null);
  if (!aliases.size) return response;
  const normalize = (item: unknown): boolean => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) return false;
    const value = item as Record<string, unknown>;
    if (value['type'] !== 'function_call' || value['namespace'] !== undefined && value['namespace'] !== null && value['namespace'] !== '') return false;
    const alias = aliases.get(String(value['name']));
    if (!alias) return false;
    Object.assign(value, alias);
    return true;
  };
  const rewrite = (line: string): string => {
    if (!line.startsWith('data:')) return line;
    try {
      const data = JSON.parse(line.slice(5)) as Record<string, unknown>;
      let changed = normalize(data['item']);
      const output = (data['response'] as { output?: unknown[] } | undefined)?.output;
      if (Array.isArray(output)) for (const item of output) changed = normalize(item) || changed;
      return changed ? `data: ${JSON.stringify(data)}${line.endsWith('\r') ? '\r' : ''}` : line;
    } catch { return line; }
  };
  // Preserve line endings and unmodified frames. Large lines bypass parsing;
  // buffer at most 1 MiB and use the stream's existing backpressure/cancellation.
  const decoder = new TextDecoder(), encoder = new TextEncoder();
  let pending = '', oversized = false;
  const consume = (text: string, controller: TransformStreamDefaultController<Uint8Array>) => {
    pending += text;
    let end: number;
    while ((end = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, end); pending = pending.slice(end + 1);
      controller.enqueue(encoder.encode((oversized || line.length > 1024 * 1024 ? line : rewrite(line)) + '\n'));
      oversized = false;
    }
    if (pending.length > 1024 * 1024) { controller.enqueue(encoder.encode(pending)); pending = ''; oversized = true; }
  };
  const stream = response.body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) { consume(decoder.decode(chunk, { stream: true }), controller); },
    flush(controller) {
      consume(decoder.decode(), controller);
      if (pending) controller.enqueue(encoder.encode(oversized ? pending : rewrite(pending)));
    },
  }));
  const headers = new Headers(response.headers); headers.delete('content-length');
  return new Response(stream, { status: response.status, headers });
}
