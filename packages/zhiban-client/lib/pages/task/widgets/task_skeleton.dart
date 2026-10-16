import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_skeleton.dart';

class TaskPageSkeleton extends StatelessWidget {
  const TaskPageSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = PlatformUtils.isMobile;
    final hPad = isMobile ? 16.0 : 24.0;

    return Column(
      children: [
        _HeaderSkeleton(horizontalPadding: hPad),
        const SizedBox(height: 16),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final spacing = isMobile ? 0.0 : 16.0;
              final contentWidth = constraints.maxWidth - hPad * 2;
              final cardWidth =
                  isMobile ? contentWidth : (contentWidth - spacing) / 2;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, hPad),
                child: SizedBox(
                  width: contentWidth,
                  child: Wrap(
                    spacing: spacing,
                    runSpacing: isMobile ? 12 : spacing,
                    children: List.generate(
                      isMobile ? 5 : 6,
                      (_) => SizedBox(
                        width: cardWidth,
                        child: const _TaskCardSkeleton(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HeaderSkeleton extends StatelessWidget {
  const _HeaderSkeleton({required this.horizontalPadding});

  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final isMobile = PlatformUtils.isMobile;
    return Container(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        isMobile ? 0 : 16,
        horizontalPadding,
        isMobile ? 4 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: isMobile
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0xFFEFF1F5))
              ),
      ),
      child: Row(
        children: [
          UiSkeletonBlock(width: isMobile ? 60 : 72, height: 22, radius: 999),
          SizedBox(width: isMobile ? 14 : 24),
          UiSkeletonBlock(width: isMobile ? 60 : 72, height: 22, radius: 999),
          Spacer(),
          UiSkeletonBlock(width: isMobile ? 34 : 72, height: 34, radius: 10),
          const SizedBox(width: 8),
          UiSkeletonBlock(width: isMobile ? 34 : 72, height: 34, radius: 10),
        ],
      ),
    );
  }
}

class _TaskCardSkeleton extends StatelessWidget {
  const _TaskCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEFF1F5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UiSkeletonBlock(width: 172, height: 18, radius: 8),
                    SizedBox(height: 9),
                    UiSkeletonBlock(
                      width: double.infinity,
                      height: 13,
                      radius: 7,
                    ),
                    SizedBox(height: 7),
                    UiSkeletonBlock(width: 190, height: 13, radius: 7),
                  ],
                ),
              ),
              SizedBox(width: 12),
              UiSkeletonBlock(width: 38, height: 22, radius: 999),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 1,
            color: const Color(0xFFF2F4F7),
          ),
          const SizedBox(height: 12),
          const Row(
            children: [
              UiSkeletonBlock(width: 14, height: 14, radius: 7),
              SizedBox(width: 8),
              UiSkeletonBlock(width: 132, height: 12, radius: 6),
              SizedBox(width: 10),
              UiSkeletonBlock(width: 96, height: 12, radius: 6),
            ],
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              UiSkeletonBlock(width: 86, height: 34, radius: 10),
              UiSkeletonBlock(width: 60, height: 34, radius: 10),
              UiSkeletonBlock(width: 60, height: 34, radius: 10),
              UiSkeletonBlock(width: 80, height: 34, radius: 10),
            ],
          ),
        ],
      ),
    );
  }
}
