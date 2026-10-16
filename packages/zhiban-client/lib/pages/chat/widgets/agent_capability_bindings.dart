import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';

/// 创建 / 编辑数字员工提交后，把 draft 选中的技能 / 应用 / 知识库一次性
/// 真绑定到后端（契约 §「应用 / 知识库真绑定」：此前应用与知识库只存
/// metadata label，从未写入绑定表，运行时不生效）。
///
/// 通讯录与数字员工广场共用此函数，保证两个编辑入口绑定行为一致。
/// 技能绑定失败不阻断应用 / 知识库绑定；返回首个错误供上层 toast 提示，
/// 全部成功返回 null。
Future<Object?> replaceAgentCapabilityBindings(
  WidgetRef ref, {
  required String agentId,
  required CreateAgentDraft draft,
}) async {
  final svc = ref.read(chatServiceProvider);
  Object? firstError;
  try {
    await svc.replaceAgentSkillBindings(
      agentId: agentId,
      skillSlugs: draft.skillSlugs,
    );
  } catch (error) {
    firstError = error;
  }
  try {
    await svc.replaceAgentAppBindings(
      agentId: agentId,
      appUuids: draft.appUuids,
    );
    await svc.replaceAgentKnowledgeBaseBindings(
      agentId: agentId,
      knowledgeBaseUuids: draft.knowledgeBaseUuids,
    );
  } catch (error) {
    firstError ??= error;
  }
  return firstError;
}
