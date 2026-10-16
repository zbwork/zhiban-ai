import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/services/skill_binding_actions.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

import 'package:zhiban_client/pages/skills/widgets/skill_card.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_icon.dart';

/// 「我的技能」视图（F03 §1.5.4 技能广场闭环）。
///
/// 按技能聚合当前用户可管理（`can_manage_skills=true`）数字员工上的正式绑定，
/// 数据完全由 `GET /agents` 的 `skills[]` 客户端聚合，不新增后端接口。
/// 支持逐数字员工「使用」（跳转对话）与「移除」（当前 slug 集合去掉该技能后
/// 调 skill-bindings，真进度进右下角任务栏）。
class MySkillsView extends ConsumerStatefulWidget {
  const MySkillsView({super.key, required this.onGoMarket});

  /// 空态引导：切回「技能广场」tab。
  final VoidCallback onGoMarket;

  @override
  ConsumerState<MySkillsView> createState() => _MySkillsViewState();
}

class _MySkillsViewState extends ConsumerState<MySkillsView> {
  /// 正在提交移除的 (agentId, slug) 组合，防重复点击。
  final Set<String> _busyKeys = <String>{};

  /// 已提交移除成功、等待 agentsProvider 后台刷新落地的组合（乐观隐藏）。
  final Set<String> _removedKeys = <String>{};

  static String _key(String agentId, String slug) => '$agentId::$slug';

  @override
  void initState() {
    super.initState();
    // 进入视图时后台刷一次，保证其它入口（对话页/编辑弹框）的绑定变更能反映出来。
    Future.microtask(() {
      if (!mounted) return;
      unawaited(ref.read(agentsProvider.notifier).refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final agentsAsync = ref.watch(agentsProvider);
    // 广场列表数据用于补足图标/计费等展示字段（尽力而为，不阻塞聚合）。
    final marketSkills =
        ref.watch(skillsProvider).asData?.value.skills ?? const <Skill>[];
    final marketBySlug = <String, Skill>{
      for (final s in marketSkills)
        if (s.slug.isNotEmpty) s.slug: s,
    };

    return agentsAsync.when(
      data: (agents) {
        final entries = _aggregate(agents);
        if (entries.isEmpty) {
          return _MySkillsEmpty(onGoMarket: widget.onGoMarket);
        }
        final bottomInset = PlatformUtils.isMobile
            ? MediaQuery.of(context).padding.bottom
            : 0.0;
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + bottomInset),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final entry = entries[index];
            return _MySkillCard(
              entry: entry,
              marketSkill: marketBySlug[entry.slug],
              busyKeys: _busyKeys,
              onUse: _openConversation,
              onRemove: (agent) => _removeFromAgent(agent, entry),
            );
          },
        );
      },
      loading: () => const Center(child: CupertinoActivityIndicator()),
      error: (error, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '数字员工列表加载失败',
              style: TextStyle(fontSize: 13.5, color: Color(0xFF667085)),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => ref.invalidate(agentsProvider),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  List<_MySkillEntry> _aggregate(List<AgentItem> agents) {
    final bySlug = <String, _MySkillEntry>{};
    for (final agent in agents) {
      if (!agent.canManageSkills) continue;
      for (final s in agent.skills) {
        if (!s.isInstalled || s.slug.isEmpty) continue;
        if (_removedKeys.contains(_key(agent.agentId, s.slug))) continue;
        final entry = bySlug.putIfAbsent(
          s.slug,
          () => _MySkillEntry(slug: s.slug, sample: s),
        );
        entry.agents.add(agent);
      }
    }
    final entries = bySlug.values.toList(growable: false);
    entries.sort((a, b) => a.displayName.compareTo(b.displayName));
    return entries;
  }

  Future<void> _openConversation(AgentItem agent) async {
    try {
      await openAgentDirectConversation(ref, agent: agent);
    } catch (_) {
      BotToast.showText(text: '打开对话失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    if (PlatformUtils.isMobile) {
      context.push(RoutePaths.chatConversation);
    } else {
      context.go(RoutePaths.chat);
    }
  }

  Future<void> _removeFromAgent(AgentItem agent, _MySkillEntry entry) async {
    final key = _key(agent.agentId, entry.slug);
    if (_busyKeys.contains(key)) return;
    final confirmed = await showUiConfirmDialog(
      context,
      title: '移除「${entry.displayName}」',
      description: '将从「${agent.displayName}」移除该技能，移除后该数字员工不能再使用它。',
      confirmLabel: '移除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyKeys.add(key));
    try {
      final slugs = installedSkillSlugs(agent)
          .where((slug) => slug != entry.slug)
          .toList(growable: false);
      await replaceAgentSkillsAndSync(ref, agent: agent, slugs: slugs);
      if (!mounted) return;
      setState(() {
        _busyKeys.remove(key);
        _removedKeys.add(key);
      });
      BotToast.showText(text: '已移除');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busyKeys.remove(key));
      BotToast.showText(text: '移除失败，请稍后重试');
    }
  }
}

/// slug 维度聚合项：一项技能 + 装有它的可管理数字员工列表。
class _MySkillEntry {
  _MySkillEntry({required this.slug, required this.sample});

  final String slug;
  final AgentSkillItem sample;
  final List<AgentItem> agents = <AgentItem>[];

  String get displayName =>
      sample.skillName.isNotEmpty ? sample.skillName : slug;
}

class _MySkillCard extends StatelessWidget {
  const _MySkillCard({
    required this.entry,
    required this.marketSkill,
    required this.busyKeys,
    required this.onUse,
    required this.onRemove,
  });

  final _MySkillEntry entry;
  final Skill? marketSkill;
  final Set<String> busyKeys;
  final ValueChanged<AgentItem> onUse;
  final ValueChanged<AgentItem> onRemove;

  @override
  Widget build(BuildContext context) {
    final iconUrl = entry.sample.iconUrl.isNotEmpty
        ? entry.sample.iconUrl
        : (marketSkill?.iconUrl ?? '');
    final description = marketSkill?.description ?? '';
    final isPaid = entry.sample.isPaid || (marketSkill?.isPaid ?? false);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF101828).withValues(alpha: 0.035),
            blurRadius: 10,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SkillIcon(
                iconUrl: iconUrl,
                size: 44,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1D2129),
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (marketSkill != null) ...[
                          const SizedBox(width: 6),
                          SkillBillingBadge(skill: marketSkill!),
                        ] else if (isPaid) ...[
                          const SizedBox(width: 6),
                          const _PaidBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description.isNotEmpty
                          ? description
                          : '已添加到 ${entry.agents.length} 个数字员工',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF86909C),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '已添加到 ${entry.agents.length} 个数字员工',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFB8BDC6),
                  height: 1.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: const Color(0xFFF1F4F8)),
          const SizedBox(height: 6),
          for (final agent in entry.agents)
            _MySkillAgentRow(
              agent: agent,
              busy: busyKeys.contains('${agent.agentId}::${entry.slug}'),
              onUse: () => onUse(agent),
              onRemove: () => onRemove(agent),
            ),
        ],
      ),
    );
  }
}

class _PaidBadge extends StatelessWidget {
  const _PaidBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        '付费',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color(0xFFD97706),
          height: 1.3,
        ),
      ),
    );
  }
}

class _MySkillAgentRow extends StatelessWidget {
  const _MySkillAgentRow({
    required this.agent,
    required this.busy,
    required this.onUse,
    required this.onRemove,
  });

  final AgentItem agent;
  final bool busy;
  final VoidCallback onUse;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _RowAvatar(avatarUrl: agent.avatarUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              agent.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF344054),
                height: 1.3,
              ),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: CupertinoActivityIndicator(radius: 8),
            )
          else ...[
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1677FF),
                minimumSize: const Size(48, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: onUse,
              child: const Text('使用'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFD92D20),
                minimumSize: const Size(48, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: onRemove,
              child: const Text('移除'),
            ),
          ],
        ],
      ),
    );
  }
}

class _RowAvatar extends StatelessWidget {
  const _RowAvatar({required this.avatarUrl});

  final String avatarUrl;

  @override
  Widget build(BuildContext context) {
    const size = 28.0;
    if (avatarUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFE7EEFF),
          borderRadius: BorderRadius.circular(size / 2),
        ),
        alignment: Alignment.center,
        child: const Icon(
          CupertinoIcons.person_fill,
          size: 15,
          color: Color(0xFF3D6AD6),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: SizedBox(
        width: size,
        height: size,
        child: UiNetworkImage(
          imageUrl: avatarUrl,
          fit: BoxFit.cover,
          clip: false,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFFE7EEFF),
            alignment: Alignment.center,
            child: const Icon(
              CupertinoIcons.person_fill,
              size: 15,
              color: Color(0xFF3D6AD6),
            ),
          ),
        ),
      ),
    );
  }
}

class _MySkillsEmpty extends StatelessWidget {
  const _MySkillsEmpty({required this.onGoMarket});

  final VoidCallback onGoMarket;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.square_grid_2x2,
            size: 36,
            color: Color(0xFFB8BDC6),
          ),
          const SizedBox(height: 14),
          const Text(
            '还没有为数字员工添加技能',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF344054),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '去技能广场挑选技能，添加到你创建的数字员工。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: Color(0xFF8A93A6),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF3B6FE5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              textStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: onGoMarket,
            child: const Text('去技能广场看看'),
          ),
        ],
      ),
    );
  }
}
