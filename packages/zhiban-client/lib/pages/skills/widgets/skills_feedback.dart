import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/config/skeleton_config.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_skeleton.dart';

class SkillsInlineMessage extends StatelessWidget {
  const SkillsInlineMessage({
    required this.icon,
    required this.text,
    required this.backgroundColor,
    required this.textColor,
    super.key,
  });

  final IconData icon;
  final String text;
  final Color backgroundColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: textColor)
            ),
          ),
        ],
      ),
    );
  }
}

class SkillsShimmerLoading extends StatelessWidget {
  const SkillsShimmerLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = PlatformUtils.isMobile;
    if (isMobile) {
      return Column(
        children: List.generate(
          6,
          (index) => const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: _SkillsSkeletonCard(mobile: true),
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 10,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisSpacing: 14,
        crossAxisSpacing: 18,
        mainAxisExtent: 104,
      ),
      itemBuilder: (_, __) => const _SkillsSkeletonCard(mobile: false),
    );
  }
}

class _SkillsSkeletonCard extends StatelessWidget {
  const _SkillsSkeletonCard({required this.mobile});

  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SkeletonConfig.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SkeletonConfig.block),
      ),
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(left: mobile ? 14 : 18),
            child: UiSkeletonBlock(
              width: mobile ? 48 : 56,
              height: mobile ? 48 : 56,
              radius: 14,
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                mobile ? 12 : 14,
                18,
                mobile ? 14 : 16,
                18,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  UiSkeletonBlock(width: 120, height: 16, radius: 8),
                  SizedBox(height: 8),
                  UiSkeletonBlock(
                    width: double.infinity,
                    height: 13,
                    radius: 7,
                  ),
                  SizedBox(height: 8),
                  UiSkeletonBlock(width: 110, height: 12, radius: 6),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SkillsLoadingItem extends StatelessWidget {
  const SkillsLoadingItem({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: CupertinoActivityIndicator(radius: 11),
      ),
    );
  }
}

class SkillsEmpty extends StatelessWidget {
  const SkillsEmpty({this.error, super.key});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_mosaic_rounded,
              size: 44,
              color: Color(0xFF98A2B3),
            ),
            const SizedBox(height: 12),
            const Text(
              '没有查到匹配的技能',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF162033),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error == null ? '可以试试更换关键词、来源或排序方式。' : '请求返回成功，但当前没有解析出可展示的技能数据。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Color(0xFF667085),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
