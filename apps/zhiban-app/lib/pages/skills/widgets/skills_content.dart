import 'package:zhiban_client/pages/skills/widgets/skills_feedback.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_card.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

class SkillsContent extends StatelessWidget {
  const SkillsContent({
    required this.state,
    required this.scrollController,
    required this.onSkillTap,
    required this.onSkillAdd,
    required this.onLoadMore,
    super.key,
  });

  final SkillsListState state;
  final ScrollController scrollController;
  final ValueChanged<Skill> onSkillTap;

  /// 卡片尾部「添加」直达按钮（F03 §1.5.4 技能广场闭环）。
  final ValueChanged<Skill> onSkillAdd;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final bool showListLoading = state.skills.isEmpty && state.isLoading;
    final bool showLoadMoreLoading = state.skills.isNotEmpty && state.isLoading;
    if (state.skills.isEmpty && !showListLoading) {
      return SkillsEmpty(error: state.error);
    }

    final categoryNames = <int, String>{
      for (final c in state.categories) c.id: c.name,
    };
    String? categoryNameOf(Skill skill) {
      final id = skill.categoryId;
      if (id == null) return null;
      return categoryNames[id];
    }

    final list = ListView(
      controller: scrollController,
      // 顶部留白：卡片区不贴筛选栏。
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
      children: [
        if (showListLoading) ...[
          const SkillsShimmerLoading(),
          const SizedBox(height: 12),
        ],
        if (state.error != null) ...[
          SkillsInlineMessage(
            icon: Icons.info_outline_rounded,
            text: state.error!,
            backgroundColor: const Color(0xFFFFF4ED),
            textColor: const Color(0xFFB54708),
          ),
          const SizedBox(height: 12),
        ],
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: state.skills.length,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 360,
            mainAxisSpacing: 14,
            crossAxisSpacing: 18,
            // 设计稿版式：30(上下padding) + 56(icon 头行) + 12
            // + ≤39(2行描述) + 10 + 36(在用/添加行) + 23(分隔) + ≤38(2行示例) ≈ 244。
            mainAxisExtent: 246,
          ),
          itemBuilder: (context, index) => SkillCard(
            skill: state.skills[index],
            categoryName: categoryNameOf(state.skills[index]),
            onTap: () => onSkillTap(state.skills[index]),
            onAdd: () => onSkillAdd(state.skills[index]),
          ),
        ),
        if (showLoadMoreLoading) ...[
          const SizedBox(height: 16),
          const SkillsLoadingItem(),
        ] else if (!state.hasReachedMax && state.skills.isNotEmpty) ...[
          const SizedBox(height: 16),
          _LoadMoreTrigger(onLoadMore: onLoadMore),
        ],
      ],
    );

    return list;
  }
}

class _LoadMoreTrigger extends StatelessWidget {
  const _LoadMoreTrigger({required this.onLoadMore});

  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: const Key('skills-load-more'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction > 0) onLoadMore();
      },
      child: const Center(
        child: Text(
          '继续下滑加载更多技能',
          style: TextStyle(
            fontSize: 13,
            color: Color(0xFF98A2B3),
          ),
        ),
      ),
    );
  }
}
