import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/services/skill_binding_actions.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

/// 「选择安装到哪个数字员工」弹框（F03 §1.5.4 技能广场闭环）。
///
/// - 只列出当前用户可管理（`can_manage_skills=true`，即自己创建且非 ZAP）的数字员工；
/// - 已装该技能的行展示「使用」→ 跳转到与该数字员工的对话；
/// - 未装的展示「添加」→ 付费确认（如需）后调正式绑定接口，成功后行内就地翻转；
/// - Bus 会再次校验创建者 / ZAP / 租户边界，前端布尔字段只决定可见性。
Future<void> showSkillInstallAgentDialog(
  BuildContext context, {
  required Skill skill,
}) {
  final container = ProviderScope.containerOf(context);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: SkillInstallAgentDialog(skill: skill),
    ),
  );
}

class SkillInstallAgentDialog extends ConsumerStatefulWidget {
  const SkillInstallAgentDialog({super.key, required this.skill});

  final Skill skill;

  @override
  ConsumerState<SkillInstallAgentDialog> createState() =>
      _SkillInstallAgentDialogState();
}

class _SkillInstallAgentDialogState
    extends ConsumerState<SkillInstallAgentDialog> {
  /// 正在提交绑定 / 正在打开对话的数字员工。
  final Set<String> _busyAgentIds = <String>{};

  /// 本次弹框内刚添加成功的数字员工（agentsProvider 后台刷新前先就地翻转）。
  final Set<String> _installedAgentIds = <String>{};

  bool _isInstalled(AgentItem agent) {
    if (_installedAgentIds.contains(agent.agentId)) return true;
    return agent.skills
        .any((s) => s.slug == widget.skill.slug && s.isInstalled);
  }

  @override
  Widget build(BuildContext context) {
    final agentsAsync = ref.watch(agentsProvider);

    return UiPickerDialog(
      size: UiDialogSize.standard,
      maxHeight: 640,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 20, 4),
            child: UiSheetHeader(
              title: '选择安装到哪个数字员工',
              subtitle: '将「${widget.skill.displayTitle}」添加到选中的数字员工',
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: agentsAsync.when(
              data: (agents) {
                final manageable = agents
                    .where((a) => a.canManageSkills)
                    .toList(growable: false);
                if (manageable.isEmpty) {
                  return const _InstallTargetEmpty();
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
                  shrinkWrap: true,
                  itemCount: manageable.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final agent = manageable[index];
                    return _InstallTargetTile(
                      agent: agent,
                      installed: _isInstalled(agent),
                      busy: _busyAgentIds.contains(agent.agentId),
                      onAdd: () => _addToAgent(agent),
                      onUse: () => _useWithAgent(agent),
                    );
                  },
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CupertinoActivityIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '数字员工列表加载失败',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: Color(0xFF667085),
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => ref.invalidate(agentsProvider),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addToAgent(AgentItem agent) async {
    if (_busyAgentIds.contains(agent.agentId)) return;
    final skill = widget.skill;
    if (skill.isPaid) {
      final confirmed = await showUiConfirmDialog(
        context,
        title: skill.displayTitle,
        description: skill.billingHintText,
        confirmLabel: '继续添加',
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _busyAgentIds.add(agent.agentId));
    try {
      final slugs = installedSkillSlugs(agent);
      if (!slugs.contains(skill.slug)) slugs.add(skill.slug);
      await replaceAgentSkillsAndSync(ref, agent: agent, slugs: slugs);
      if (!mounted) return;
      setState(() {
        _busyAgentIds.remove(agent.agentId);
        _installedAgentIds.add(agent.agentId);
      });
      BotToast.showText(text: '已添加到「${agent.displayName}」');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busyAgentIds.remove(agent.agentId));
      BotToast.showText(text: '添加失败，请稍后重试');
    }
  }

  Future<void> _useWithAgent(AgentItem agent) async {
    if (_busyAgentIds.contains(agent.agentId)) return;
    setState(() => _busyAgentIds.add(agent.agentId));
    try {
      await openAgentDirectConversation(ref, agent: agent);
    } catch (_) {
      if (mounted) {
        setState(() => _busyAgentIds.remove(agent.agentId));
      }
      BotToast.showText(text: '打开对话失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    // 先取好导航句柄再关弹框：pop 之后当前 element 已失效，不能再用 context。
    final navigator = Navigator.of(context, rootNavigator: true);
    final router = GoRouter.of(context);
    navigator.popUntil((route) => route.isFirst);
    if (PlatformUtils.isMobile) {
      router.push(RoutePaths.chatConversation);
    } else {
      router.go(RoutePaths.chat);
    }
  }
}

class _InstallTargetEmpty extends StatelessWidget {
  const _InstallTargetEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 44, 24, 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.person_2,
              size: 34,
              color: Color(0xFFB8BDC6)
            ),
            SizedBox(height: 12),
            Text(
              '暂无可添加技能的数字员工',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF344054),
              ),
            ),
            SizedBox(height: 6),
            Text(
              '只有你创建的数字员工才能添加技能，\n先去「数字员工」页创建一个吧。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Color(0xFF8A93A6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallTargetTile extends StatelessWidget {
  const _InstallTargetTile({
    required this.agent,
    required this.installed,
    required this.busy,
    required this.onAdd,
    required this.onUse,
  });

  final AgentItem agent;
  final bool installed;
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = <String>[
      if (agent.departmentName.isNotEmpty) agent.departmentName,
      if (agent.positionLabel.isNotEmpty) agent.positionLabel,
    ];
    final subtitle = subtitleParts.join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEDEFF5)),
      ),
      child: Row(
        children: [
          _AgentAvatar(avatarUrl: agent.avatarUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  agent.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF162033),
                    height: 1.3,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF7A8499),
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: CupertinoActivityIndicator(radius: 9),
            )
          else if (installed)
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1677FF),
                side: const BorderSide(color: Color(0xFFBFD9FF)),
                backgroundColor: Colors.white,
                minimumSize: const Size(64, 34),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: onUse,
              child: const Text('使用'),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF3B6FE5),
                minimumSize: const Size(64, 34),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: onAdd,
              child: const Text('添加'),
            ),
        ],
      ),
    );
  }
}

class _AgentAvatar extends StatelessWidget {
  const _AgentAvatar({required this.avatarUrl});

  final String avatarUrl;

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
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
          size: 20,
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
              size: 20,
              color: Color(0xFF3D6AD6),
            ),
          ),
        ),
      ),
    );
  }
}
