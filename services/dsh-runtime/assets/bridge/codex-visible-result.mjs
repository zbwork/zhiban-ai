/** Business event preview only. The unmodified MCP result is delivered to the model. */
export function visibleResult(value, depth = 0) {
  if (depth > 8) return { note: '嵌套工具结果已省略' };
  if (!value || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(item => visibleResult(item, depth + 1));
  if (value.type === 'image' || value.type === 'audio') return { type: value.type, mimeType: value.mimeType, note: '媒体已传给模型' };
  if (value.type === 'resource' && value.resource?.blob) return { type: 'resource', resource: { uri: value.resource.uri, mimeType: value.resource.mimeType }, note: '媒体已传给模型' };
  const result = { ...value };
  if (Array.isArray(result.content)) result.content = result.content.map(item => visibleResult(item, depth + 1));
  // Codex can wrap the MCP result in one or more text/JSON content blocks.
  if (result.type === 'text' && typeof result.text === 'string' && result.text.trimStart().startsWith('{')) {
    try {
      const parsed = JSON.parse(result.text);
      if (Array.isArray(parsed.content)) result.text = JSON.stringify(visibleResult(parsed, depth + 1));
    } catch { /* Ordinary non-JSON tool text stays intact. */ }
  }
  return result;
}
