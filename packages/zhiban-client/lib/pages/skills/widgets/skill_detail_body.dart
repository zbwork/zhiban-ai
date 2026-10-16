import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';

class SkillDetailBody extends ConsumerStatefulWidget {
  const SkillDetailBody({
    required this.skill,
    required this.onClose,
    super.key,
  });

  final Skill skill;
  final VoidCallback onClose;

  @override
  ConsumerState<SkillDetailBody> createState() => _SkillDetailBodyState();
}

class _SkillDetailBodyState extends ConsumerState<SkillDetailBody> {
  bool _isMutating = false;
  _ActionFeedback? _feedback;
  late Skill _currentSkill = widget.skill;

  Future<void> _toggleSkill(Skill skill) async {
    setState(() => _isMutating = true);
    try {
      if (skill.isInstalled) {
        await ref.read(skillsProvider.notifier).uninstallSkill(skill.slug);
        if (mounted) {
          setState(() {
            _currentSkill = skill.copyWith(
              isInstalled: false,
              installStatus: 'uninstalled',
            );
            _feedback = _ActionFeedback.success('${skill.displayTitle} 已卸载');
          });
        }
      } else {
        final installedSkill =
            await ref.read(skillsProvider.notifier).installSkill(skill.slug);
        if (mounted) {
          setState(() {
            _currentSkill = installedSkill;
            _feedback = _ActionFeedback.success(
              '${installedSkill.displayTitle} 已安装',
            );
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _feedback = _ActionFeedback.error('操作失败：$error');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final skill = _currentSkill;
    final actionLabel = skill.isInstalled ? '卸载技能' : '安装技能';
    final showInstallAction = skill.supportsInstallAction;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    skill.displayTitle,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF162033),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    skill.slug,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF98A2B3),
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: widget.onClose,
                borderRadius: BorderRadius.circular(10),
                child: const SizedBox(
                  width: 34,
                  height: 34,
                  child: Center(
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Color(0xFF667085),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            UiTag(
              label: skill.sourceLabel,
              backgroundColor: skill.sourceLabel == '公司内部'
                  ? const Color(0xFFE9F2FF)
                  : const Color(0xFFEAF7EE),
              textColor: skill.sourceLabel == '公司内部'
                  ? const Color(0xFF175CD3)
                  : const Color(0xFF027A48),
            ),
            UiTag(
              label: '下载 ${skill.downloadCount}',
              backgroundColor: const Color(0xFFF2F4F7),
              textColor: const Color(0xFF344054),
            ),
            UiTag(
              label: '最新版本 ${skill.displayVersion}',
              backgroundColor: const Color(0xFFF2F4F7),
              textColor: const Color(0xFF344054),
            ),
            UiTag(
              label: '文件大小 ${skill.displayFileSize}',
              backgroundColor: const Color(0xFFF2F4F7),
              textColor: const Color(0xFF344054),
            ),
            if (skill.isInstalled)
              UiTag(
                label: '已安装',
                backgroundColor: const Color(0xFFE8F8F2),
                textColor: const Color(0xFF157F5A),
              ),
          ],
        ),
        if (_feedback != null) ...[
          const SizedBox(height: 14),
          _ActionFeedbackBanner(feedback: _feedback!),
        ],
        const SizedBox(height: 18),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFE4E7EC)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 16,
                      color: Color(0xFF667085),
                    ),
                    SizedBox(width: 6),
                    Text(
                      '技能说明',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF344054),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      skill.description.isEmpty ? '暂无描述' : skill.description,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.7,
                        color: Color(0xFF475467),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFD0D5DD)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('关闭'),
                ),
              ),
            ),
            if (showInstallAction) ...[
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: skill.isInstalled
                          ? const Color(0xFFD92D20)
                          : const Color(0xFF2457F5),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _isMutating ? null : () => _toggleSkill(skill),
                    icon: _isMutating
                        ? const CupertinoActivityIndicator(
                            radius: 9,
                            color: Colors.white,
                          )
                        : Icon(
                            skill.isInstalled
                                ? Icons.delete_outline_rounded
                                : Icons.add_rounded,
                            size: 18,
                          ),
                    label: Text(
                      _isMutating
                          ? (skill.isInstalled ? '卸载中' : '安装中')
                          : actionLabel,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ActionFeedback {
  const _ActionFeedback._({required this.message, required this.isSuccess});

  const _ActionFeedback.success(String message)
      : this._(message: message, isSuccess: true);

  const _ActionFeedback.error(String message)
      : this._(message: message, isSuccess: false);

  final String message;
  final bool isSuccess;
}

class _ActionFeedbackBanner extends StatelessWidget {
  const _ActionFeedbackBanner({required this.feedback});

  final _ActionFeedback feedback;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: feedback.isSuccess
            ? const Color(0xFFE8F8F2)
            : const Color(0xFFFFF4ED),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: feedback.isSuccess
              ? const Color(0xFFB7E4C7)
              : const Color(0xFFFEC84B),
        ),
      ),
      child: Text(
        feedback.message,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: feedback.isSuccess
              ? const Color(0xFF027A48)
              : const Color(0xFFB54708),
        ),
      ),
    );
  }
}
