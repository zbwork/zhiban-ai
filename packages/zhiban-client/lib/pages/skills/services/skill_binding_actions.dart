import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';

/// 技能广场闭环（F03 §1.5.4）：把某数字员工的正式技能绑定替换为 [slugs] 并触发运行环境同步。
///
/// 提交边界与对话页「添加技能」一致：本函数只等待
/// `PUT /agents/{uuid}/skill-bindings`；数字员工摘要刷新与 runtime ensure
/// 在后台继续，安装/卸载真进度由全局右下角任务栏承接。
/// 绑定失败时直接抛出且不触发 ensure，由调用方提示。
Future<void> replaceAgentSkillsAndSync(
  WidgetRef ref, {
  required AgentItem agent,
  required List<String> slugs,
}) async {
  await ref.read(chatServiceProvider).replaceAgentSkillBindings(
        agentId: agent.agentId,
        skillSlugs: slugs
      );
  unawaited(refreshAgentSkillSummary(ref, agentId: agent.agentId));
  if (agent.executionLocus != 'local' &&
      ref.read(cloudRuntimePrewarmEnabledProvider)) {
    unawaited(ref.read(prewarmControllerProvider.notifier).ensureNow());
  }
}

/// 数字员工当前正式已装技能 slug 列表（保持后端返回顺序、去重）。
List<String> installedSkillSlugs(AgentItem agent) {
  final out = <String>[];
  for (final s in agent.skills) {
    if (s.isInstalled && s.slug.isNotEmpty && !out.contains(s.slug)) {
      out.add(s.slug);
    }
  }
  return out;
}

/// 绑定成功后刷新数字员工列表，并把当前选中的数字员工同步为最新数据。
///
/// 刷新失败不回滚成功态（正式绑定已落库），留给后续 provider 刷新校正。
Future<void> refreshAgentSkillSummary(
  WidgetRef ref, {
  required String agentId,
}) async {
  try {
    await ref.read(agentsProvider.notifier).refresh();
    final agents =
        ref.read(agentsProvider).asData?.value ?? const <AgentItem>[];
    AgentItem? refreshed;
    for (final item in agents) {
      if (item.agentId == agentId) {
        refreshed = item;
        break;
      }
    }
    final selected = ref.read(selectedAgentProvider).asData?.value;
    if (refreshed != null && selected?.agentId == agentId) {
      ref.read(selectedAgentProvider.notifier).refreshCurrent(refreshed);
    }
  } catch (_) {
    // 正式绑定已经成功；列表刷新失败留给后续 provider 刷新校正，不回滚成功态。
  }
}
