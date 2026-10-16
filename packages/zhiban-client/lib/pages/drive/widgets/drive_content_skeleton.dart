import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_skeleton.dart';

class DriveContentSkeleton extends StatelessWidget {
  const DriveContentSkeleton({
    super.key,
    this.compact = false,
    this.compactHeader = false,
  });

  final bool compact;
  final bool compactHeader;

  @override
  Widget build(BuildContext context) {
    final hPad = compact ? 16.0 : 32.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, compact ? 14 : 24, hPad, 16),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!compactHeader) ...[
                      const UiSkeletonBlock(
                        width: 168,
                        height: 18,
                        radius: 9
                      ),
                      const SizedBox(height: 12),
                    ],
                    const Row(
                      children: [
                        Expanded(
                          child: UiSkeletonBlock(
                            width: double.infinity,
                            height: 36,
                            radius: 10,
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: UiSkeletonBlock(
                            width: double.infinity,
                            height: 36,
                            radius: 10,
                          ),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    if (!compactHeader)
                      const Expanded(
                        child: UiSkeletonBlock(
                          width: double.infinity,
                          height: 18,
                          radius: 9,
                        ),
                      )
                    else
                      const Spacer(),
                    const SizedBox(width: 16),
                    const UiSkeletonBlock(width: 92, height: 36, radius: 10),
                    const SizedBox(width: 8),
                    const UiSkeletonBlock(width: 92, height: 36, radius: 10),
                  ],
                ),
        ),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 32),
            itemCount: compact ? 7 : 9,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, index) => _DriveListRowSkeleton(
              compact: compact,
              shortName: index.isOdd
            ),
          ),
        ),
      ],
    );
  }
}

class _DriveListRowSkeleton extends StatelessWidget {
  const _DriveListRowSkeleton({
    required this.compact,
    required this.shortName
  });

  final bool compact;
  final bool shortName;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 12 : 14,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFEFF1F5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const UiSkeletonBlock(width: 32, height: 32, radius: 8),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UiSkeletonBlock(
                  width: shortName ? 124 : 188,
                  height: 14,
                  radius: 7,
                ),
                const SizedBox(height: 8),
                const UiSkeletonBlock(width: 108, height: 12, radius: 6),
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 16),
            const UiSkeletonBlock(width: 88, height: 12, radius: 6),
            const SizedBox(width: 24),
            const UiSkeletonBlock(width: 72, height: 12, radius: 6),
          ],
        ],
      ),
    );
  }
}
