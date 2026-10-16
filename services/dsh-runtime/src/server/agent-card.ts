import type { AgentRecord } from '../store/agent-store.js';
import { RUNTIME_UI_COMPONENTS } from './runtime-card.js';

/** AgentCard（ZAP v1.0 §3 schema 的最小合规子集）。 */
export function buildAgentCard(agent: AgentRecord): Record<string, unknown> {
  return {
    schema_version: 'zap-1.1',
    agent_key: agent.agent_key,
    name: agent.name,
    version: String(agent.revision),
    status: 'active',
    ...(agent.model ? { model: agent.model } : {}),
    tools: Array.isArray(agent.tools) ? agent.tools : [],
    ui_components: agent.ui_components ?? ['markdown', 'error', 'tool_call', 'tool_result'],
    interaction_modes: {
      streaming: true,
      multi_turn: true,
      approval: false,
      form_back: false,
      tool_handoff: false,
      parallel_groupchat: false,
      ...(agent.interaction_modes ?? {}),
    },
    ...(agent.limits ? { limits: agent.limits } : {}),
    metadata: agent.metadata ?? {},
  };
}

/** Bus client.go AgentInfo 形状（list / card 里的 agent 条目）。 */
export function agentInfo(agent: AgentRecord): Record<string, unknown> {
  return {
    agent_key: agent.agent_key,
    name: agent.name,
    version: String(agent.revision),
    status: 'active',
    ...(agent.model ? { model: agent.model } : {}),
    ...(agent.tools !== undefined ? { tools: agent.tools } : {}),
  };
}

export function validateUiComponents(list: string[] | undefined): string | undefined {
  if (!list) return undefined;
  const allowed = new Set<string>(RUNTIME_UI_COMPONENTS);
  const bad = list.filter((c) => !allowed.has(c));
  return bad.length > 0 ? bad.join(',') : undefined;
}
