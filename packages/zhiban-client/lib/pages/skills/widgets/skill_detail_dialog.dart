import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:zhiban_client/pages/chat/widgets/messages/chat_markdown.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'skill_card.dart';
import 'skill_icon.dart';
import 'skill_install_agent_dialog.dart';

/// 技能广场详情弹框（共用）。
///
/// 区块顺序：
/// - 头部：图标 + 技能名 + 元信息行（来源 / 版本 / N人添加）+ 完整技能描述 + 关闭按钮
/// - 使用示例（usageExample 非空时）
/// - 示例图片（usageExampleImages 非空时）
/// - 底部提示：示例内容由 AI 生成，仅供参考
/// - [enableInstall] 为 true 时底部展示主「添加」按钮 → 打开
///   「选择安装到哪个数字员工」弹框（F03 §1.5.4 技能广场闭环）。
///
/// 弹框使用 standard 640px 与技能选择器保持一致，最大高度 760px。
class SkillDetailDialog extends StatelessWidget {
  const SkillDetailDialog({
    super.key,
    required this.skill,
    this.enableInstall = false,
  });

  final Skill skill;

  /// 技能广场入口传 true；技能选择器内的详情预览保持 false（选择器自身负责绑定）。
  final bool enableInstall;

  @override
  Widget build(BuildContext context) {
    final description = skill.description.trim();
    final usageExample = skill.usageExample.trim();
    final usageImages = skill.usageExampleImages;
    final hasContent = usageExample.isNotEmpty || usageImages.isNotEmpty;

    return UiContentDialog(
      maxHeight: 760,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SkillDetailHeader(skill: skill, description: description),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (usageExample.isNotEmpty)
                    _SkillDetailSection(
                      icon: CupertinoIcons.list_bullet,
                      title: '使用步骤',
                      child: ChatMarkdownWidget(
                        content: usageExample,
                        compact: true,
                        linkTapBehavior: ChatMarkdownLinkTapBehavior.confirm,
                      ),
                    ),
                  if (usageImages.isNotEmpty) ...[
                    if (usageExample.isNotEmpty) const SizedBox(height: 14),
                    _SkillDetailSection(
                      icon: CupertinoIcons.photo_on_rectangle,
                      title: '使用示例',
                      child: _SkillUsageImageGrid(images: usageImages),
                    ),
                  ],
                  if (hasContent) ...[
                    const SizedBox(height: 14),
                    const _AiGeneratedHint(),
                    const UiAiGeneratedLabel(),
                  ],
                ],
              ),
            ),
          ),
          if (enableInstall) _SkillDetailInstallBar(skill: skill),
        ],
      ),
    );
  }
}

class _SkillDetailInstallBar extends StatelessWidget {
  const _SkillDetailInstallBar({required this.skill});

  final Skill skill;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F4F8))),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF3B6FE5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          // 保持详情弹框打开，在其上层弹出目标数字员工选择器（对齐竞品交互）。
          onPressed: () => showSkillInstallAgentDialog(context, skill: skill),
          child: const Text('添加'),
        ),
      ),
    );
  }
}

class _SkillDetailHeader extends StatelessWidget {
  const _SkillDetailHeader({required this.skill, required this.description});

  final Skill skill;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
          child: UiSheetHeader(
            title: '技能详情',
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkillIcon(
                iconUrl: skill.iconUrl,
                size: 56,
                borderRadius: BorderRadius.circular(14),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              skill.displayTitle,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF101828),
                                height: 1.25,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SkillBillingBadge(skill: skill),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _SkillDetailMetaLine(skill: skill),
                      if (skill.isPaid) ...[
                        const SizedBox(height: 6),
                        Text(
                          skill.billingHintText,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFD97706),
                            height: 1.4,
                          ),
                        ),
                      ],
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          description,
                          style: const TextStyle(
                            fontSize: 13.5,
                            height: 1.7,
                            color: Color(0xFF667085),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 元信息行：来源 · 最新版本 · N人添加（F03 §1.5.4）。
class _SkillDetailMetaLine extends StatelessWidget {
  const _SkillDetailMetaLine({required this.skill});

  final Skill skill;

  @override
  Widget build(BuildContext context) {
    final source = SkillSourceMeta.fromSkill(skill);
    final version = skill.displayVersion;
    final items = <Widget>[
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(source.icon, size: 13, color: source.color),
          const SizedBox(width: 4),
          Text(source.label, style: _metaStyle),
        ],
      ),
      if (version != '--') Text('v$version', style: _metaStyle),
      Text(
        '${formatSkillInstallCount(skill.downloadCount)}人在用',
        style: _metaStyle,
      ),
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i != 0)
            Container(
              width: 1,
              height: 10,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: const Color(0xFFE5E6EB),
            ),
          items[i],
        ],
      ],
    );
  }

  static const _metaStyle = TextStyle(
    fontSize: 12,
    color: Color(0xFF86909C),
    height: 1.3,
  );
}

class _SkillDetailSection extends StatelessWidget {
  const _SkillDetailSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEDEFF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: const Color(0xFF6366F1)),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF344054),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _AiGeneratedHint extends StatelessWidget {
  const _AiGeneratedHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 12,
            color: Color(0xFF98A2B3),
          ),
          SizedBox(width: 4),
          Flexible(
            child: Text(
              '示例内容由 AI 生成，仅供参考，实际效果可能因输入而异。',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: Color(0xFF98A2B3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkillUsageImageGrid extends StatelessWidget {
  const _SkillUsageImageGrid({required this.images});

  final List<SkillUsageExampleImage> images;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        // 桌面/iPad 显示按 3 列，窄屏（手机）按 2 列；单图独占一行。
        final isNarrow = constraints.maxWidth < 360;
        int perRow;
        if (images.length == 1) {
          perRow = 1;
        } else if (isNarrow) {
          perRow = 2;
        } else {
          perRow = 3;
        }
        final tileWidth =
            (constraints.maxWidth - spacing * (perRow - 1)) / perRow;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final img in images)
              _SkillUsageImageTile(
                image: img,
                width: tileWidth,
                // 单图时高度高一些，多图缩略图高度更克制。
                height:
                    images.length == 1 ? tileWidth * 0.62 : tileWidth * 1.18,
              ),
          ],
        );
      },
    );
  }
}

class _SkillUsageImageTile extends StatelessWidget {
  const _SkillUsageImageTile({
    required this.image,
    required this.width,
    required this.height,
  });

  final SkillUsageExampleImage image;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _previewImage(context, image),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: width,
          height: height,
          child: UiNetworkImage(
            imageUrl: image.url,
            fit: BoxFit.cover,
            clip: false,
            placeholderBuilder: (_, __) => Container(
              color: const Color(0xFFF2F4F7),
              alignment: Alignment.center,
              child: const CupertinoActivityIndicator(radius: 9),
            ),
            errorBuilder: (_, __, ___) => Container(
              color: const Color(0xFFF2F4F7),
              alignment: Alignment.center,
              child: const Icon(
                CupertinoIcons.photo,
                size: 22,
                color: Color(0xFF98A2B3),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _previewImage(BuildContext context, SkillUsageExampleImage image) {
    // 图片大图预览统一走 ui_image_preview，避免各页面维护各自的弹框实现。
    showImagePreviewRoute<void>(
      context: context,
      useSafeArea: Theme.of(context).platform != TargetPlatform.iOS &&
          Theme.of(context).platform != TargetPlatform.android,
      builder: (_) => UiImagePreviewDialog(fileUrl: image.url),
    );
  }
}
