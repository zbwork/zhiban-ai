import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';
import 'package:zhiban_client/pages/skills/services/skill_binding_actions.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_picker_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';

/// 已选/已添加的技能项（slug + 展示名）。
typedef SkillTagPick = ({String slug, String name});

/// 弹出"全部技能"面板（图1 样式）。
///
/// - 列出当前 agent 已安装的全部技能；
/// - 点击其中一项，关闭弹层并返回 (slug, name)，调用方将其作为输入框
///   的"已选技能"标签插入；
/// - 仅创建者底部显示 "+ 添加技能"：弹出"选择核心技能"对话框，选完后立即
///   调用正式技能绑定接口把新选 slug 合并写回，刷新列表（不关闭本层）。
///
/// 返回值：
/// - 非空：用户在面板里点了某个技能 chip，调用方应把它加到输入框；
/// - null：用户关掉了面板，没有选中任何技能。
Future<SkillTagPick?> showAgentSkillsSheet(
  BuildContext context, {
  required String agentId,
}) {
  final container = ProviderScope.containerOf(context);
  return showDialog<SkillTagPick>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: _AgentSkillsSheet(agentId: agentId),
    ),
  );
}

class _AgentSkillsSheet extends ConsumerWidget {
  const _AgentSkillsSheet({required this.agentId});

  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents =
        ref.watch(agentsProvider).asData?.value ?? const <AgentItem>[];
    AgentItem? agent;
    for (final a in agents) {
      if (a.agentId == agentId) {
        agent = a;
        break;
      }
    }
    final installed = (agent?.skills ?? const <AgentSkillItem>[])
        .where((s) => s.isInstalled)
        .toList(growable: false);

    return UiPickerDialog(
      size: UiDialogSize.standard,
      maxHeight: 720,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 20, 4),
            child: UiSheetHeader(
              title: '全部技能',
              onClose: () => Navigator.pop(context),
            ),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: installed.isEmpty
                ? const Padding(
                    padding: EdgeInsets.fromLTRB(24, 30, 24, 30),
                    child: Center(
                      child: Text(
                        '该数字员工暂未安装技能\n点击下方"添加技能"为他添加',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color: Color(0xFF8A93A6),
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    shrinkWrap: true,
                    itemCount: installed.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final s = installed[index];
                      return _InstalledSkillTile(
                        skill: s,
                        index: index,
                        onTap: () async {
                          final name =
                              s.skillName.isNotEmpty ? s.skillName : s.slug;
                          if (s.isPaid) {
                            final confirmed =
                                await _showPaidSkillConfirm(context, s);
                            if (confirmed != true) return;
                            if (!context.mounted) return;
                          }
                          Navigator.pop(
                            context,
                            (slug: s.slug, name: name)
                          );
                        },
                      );
                    },
                  ),
          ),
          if (agent?.canManageSkills == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3B6FE5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  icon: const Icon(CupertinoIcons.add, size: 18),
                  label: const Text('添加技能'),
                  onPressed: () => showAgentSkillPickerAndInstall(
                    context,
                    ref,
                    agent: agent!,
                    closeParentDialogOnCustomSkill: true,
                    closeParentDialogOnSave: true,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 打开既有技能广场并把选择结果写入数字员工正式技能绑定。
/// 调用方只在 `can_manage_skills=true` 时暴露入口；Bus 仍会再次校验创建者和 ZAP 边界。
Future<void> showAgentSkillPickerAndInstall(
  BuildContext context,
  WidgetRef ref, {
  required AgentItem agent,
  bool closeParentDialogOnCustomSkill = false,
  bool closeParentDialogOnSave = false,
}) async {
  final initialSelected = <String, String>{};
  for (final s in agent.skills) {
    if (s.isInstalled) {
      initialSelected[s.slug] = s.skillName.isNotEmpty ? s.skillName : s.slug;
    }
  }
  final container = ProviderScope.containerOf(context);
  final picked = await showDialog<Map<String, String>>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: SkillPickerDialog(
        initialSelected: initialSelected,
        agentId: agent.agentId,
        onAddCustomSkill: (ctx, _) async {
          // 关闭技能广场弹框 + 全部技能 sheet，然后切换到该 agent 并发送创建引导语。
          final nav = Navigator.of(ctx, rootNavigator: false);
          nav.pop();
          if (closeParentDialogOnCustomSkill && nav.canPop()) nav.pop();
          ref.read(selectedAgentProvider.notifier).select(agent);
          var chatState = await ref.read(chatProvider.future);
          final chatNotifier = ref.read(chatProvider.notifier);
          if (chatState.activeConversationId == null) {
            try {
              await chatNotifier.createConversation();
              chatState = await ref.read(chatProvider.future);
            } catch (_) {}
          }
          if (chatState.activeConversationId == null) {
            BotToast.showText(text: '未找到可用会话，请稍后再试');
            return;
          }
          await chatNotifier.send('我要创建个新技能');
        },
      ),
    ),
  );
  if (picked == null) return;
  if (!context.mounted) return;

  final unchanged = picked.length == initialSelected.length &&
      picked.keys.every(initialSelected.containsKey);
  if (unchanged) return;

  final closeLoading = BotToast.showLoading();
  try {
    await submitAgentSkillBindingUpdate(
      saveBindings: () =>
          ref.read(chatServiceProvider).replaceAgentSkillBindings(
                agentId: agent.agentId,
                skillSlugs: picked.keys.toList(growable: false),
              ),
      refreshAgentSummary: () => refreshAgentSkillSummary(
        ref,
        agentId: agent.agentId
      ),
      ensureRuntime: () async {
        if (agent.executionLocus != 'local' &&
            ref.read(cloudRuntimePrewarmEnabledProvider)) {
          await ref.read(prewarmControllerProvider.notifier).ensureNow();
        }
      },
    );
    closeLoading();
    if (closeParentDialogOnSave && context.mounted) {
      Navigator.of(context).pop();
    }
    BotToast.showText(
      text: agent.executionLocus == 'local' ||
              !ref.read(cloudRuntimePrewarmEnabledProvider)
          ? '技能已更新'
          : '技能已更新，正在同步运行环境',
    );
  } catch (_) {
    closeLoading();
    BotToast.showText(text: '技能更新失败，请稍后重试');
  }
}

/// 技能绑定成功即结束当前提交；摘要刷新和 runtime ensure 都在后台继续。
///
/// 该顺序保证绑定失败时不会误触发 ensure，也不会把后台安装耗时算进选择器
/// 的 loading。运行进度由全局 [PrewarmController] 和右下角任务栏承接。
@visibleForTesting
Future<void> submitAgentSkillBindingUpdate({
  required Future<void> Function() saveBindings,
  required Future<void> Function() refreshAgentSummary,
  required Future<void> Function() ensureRuntime,
}) async {
  await saveBindings();
  unawaited(refreshAgentSummary());
  unawaited(ensureRuntime());
}

Future<bool?> _showPaidSkillConfirm(
  BuildContext context,
  AgentSkillItem skill,
) {
  final name = skill.skillName.isNotEmpty ? skill.skillName : skill.slug;
  final isPerOp = skill.pricingMode == 'per_operation';
  final hint = isPerOp ? '该技能按不同接口消耗积分，是否继续？' : '使用该技能会消耗积分，是否继续？';
  return showUiConfirmDialog(
    context,
    title: name,
    description: hint,
    confirmLabel: '继续使用',
  );
}

/// 已安装技能列表的单行：浅灰圆角卡片 + 左侧 icon + 右侧标题/描述。
/// icon 颜色按 index 取色，呼应图1 的彩色色块。
class _InstalledSkillTile extends StatelessWidget {
  const _InstalledSkillTile({
    required this.skill,
    required this.index,
    required this.onTap,
  });

  final AgentSkillItem skill;
  final int index;
  final VoidCallback onTap;

  static const _palette = <({Color bg, Color fg})>[
    (bg: Color(0xFFE7EEFF), fg: Color(0xFF3D6AD6)),
    (bg: Color(0xFFE6F6EC), fg: Color(0xFF2F8F55)),
    (bg: Color(0xFFFCE9D7), fg: Color(0xFFD58A3F)),
    (bg: Color(0xFFEFE7FB), fg: Color(0xFF6B4FCB)),
    (bg: Color(0xFFFAE3E3), fg: Color(0xFFC04646)),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _palette[index % _palette.length];
    final name = skill.skillName.isNotEmpty ? skill.skillName : skill.slug;
    return Material(
      color: const Color(0xFFF4F6FB),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.bg,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  CupertinoIcons.sparkles,
                  size: 20,
                  color: color.fg
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF162033),
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (skill.isPaid) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
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
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      skill.slug,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF7A8499),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
