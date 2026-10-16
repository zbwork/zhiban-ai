import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/services/local_agent_service.dart';

/// 对话右侧顶栏（图 3 风格：紧凑文字行）。
///
/// 左侧：粗体名字 + 竖分隔 + 岗位/部门副标题（产品要求**不展示**头像 icon、不展示邮箱、不展示「在线」绿点）。
/// 右侧：搜索 / 聊天历史 / 更多 三个图标按钮，hover 浅灰底，无主功能时只是预留。
class ChatDetailHeader extends ConsumerWidget {
  const ChatDetailHeader({
    super.key,
    required this.title,
    this.agentDeleted = false,
    this.trailing,
  });

  final String title;
  final bool agentDeleted;

  /// 顶栏右侧挂载点,由调用方决定放什么(如"加人"按钮);组件本身不感知具体业务。
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(selectedAgentOrFallbackProvider);
    final agentName = agent?.name.isNotEmpty == true ? agent!.name : title;
    // 产品要求: 客户端去掉「在线」绿点; 副标题展示「部门 · 职位」, 两者按需出现。
    final dept = agent?.departmentName.trim() ?? '';
    final position = agent?.positionLabel.trim() ?? '';
    final subtitle = dept.isNotEmpty && position.isNotEmpty
        ? '$dept · $position'
        : (dept.isNotEmpty ? dept : position);

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    agentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1D2129),
                      height: 1.2,
                    ),
                  ),
                ),
                if (agent != null) ...[
                  const SizedBox(width: 12),
                  if (agent.executionLocus == 'local') ...[
                    if (agentDeleted)
                      Tooltip(
                        message: '该数字员工已删除',
                        child: Icon(
                          CupertinoIcons.desktopcomputer,
                          size: 18,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withValues(alpha: 0.55),
                        ),
                      )
                    else
                      ListenableBuilder(
                        listenable: LocalAgentService.instance,
                        builder: (context, _) {
                          final online = LocalAgentService.instance.online;
                          return Tooltip(
                            message: online ? '本机运行组件已连接' : '本机运行组件未连接',
                            child: Icon(CupertinoIcons.desktopcomputer,
                                size: 18,
                                color: online
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                          );
                        },
                      ),
                  ] else
                    Tooltip(
                      message: agentDeleted ? '该数字员工已删除' : '云端运行',
                      child: Icon(
                        CupertinoIcons.desktopcomputer,
                        size: 18,
                        color: agentDeleted
                            ? Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.55)
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  const SizedBox(width: 7),
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                          color: agentDeleted
                              ? Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.65)
                              : Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(4)),
                      child: Text(agent.executionLocus == 'local' ? '本地' : '云端',
                          style: TextStyle(
                              fontSize: 11,
                              color: agentDeleted
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                  : Theme.of(context).colorScheme.primary))),
                ],
                if (agentDeleted) ...[
                  const SizedBox(width: 8),
                  const ChatAgentDeletedBadge(),
                ],
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Container(
                    width: 1,
                    height: 14,
                    color: const Color(0xFFE5E6EB),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF86909C),
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 顶栏右侧 搜索/聊天历史/更多 三个 icon 已移除; 聊天历史功能移到输入框工具栏末尾。
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class ChatAgentDeletedBadge extends StatelessWidget {
  const ChatAgentDeletedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '已删除',
        style: TextStyle(
          fontSize: 11,
          height: 1.2,
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
