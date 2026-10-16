import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_skeleton.dart';

enum ContactsRowsKind { agent, member }

class ContactsTreeSkeleton extends StatelessWidget {
  const ContactsTreeSkeleton({super.key, this.shrinkWrap = false});
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: shrinkWrap,
      primary: !shrinkWrap,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 18),
      children: const [
        _ContactsTreeRowSkeleton(width: 96, depth: 0),
        _ContactsTreeRowSkeleton(width: 118, depth: 1),
        _ContactsTreeRowSkeleton(width: 86, depth: 2),
        _ContactsTreeRowSkeleton(width: 102, depth: 2),
        _ContactsTreeRowSkeleton(width: 112, depth: 1),
        _ContactsTreeRowSkeleton(width: 84, depth: 2),
        _ContactsTreeRowSkeleton(width: 128, depth: 0),
        _ContactsTreeRowSkeleton(width: 104, depth: 1),
      ],
    );
  }
}

class _ContactsTreeRowSkeleton extends StatelessWidget {
  const _ContactsTreeRowSkeleton({
    required this.width,
    required this.depth
  });

  final double width;
  final int depth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(depth * 18, 5, 0, 5),
      child: Row(
        children: [
          const UiSkeletonBlock(width: 18, height: 18, radius: 6),
          const SizedBox(width: 8),
          UiSkeletonBlock(width: width, height: 14, radius: 7),
        ],
      ),
    );
  }
}

class ContactsRowsSkeleton extends StatelessWidget {
  const ContactsRowsSkeleton({super.key, required this.kind});

  final ContactsRowsKind kind;

  @override
  Widget build(BuildContext context) {
    final isMobile = PlatformUtils.isMobile;
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding:
          EdgeInsets.fromLTRB(isMobile ? 16 : 32, 24, isMobile ? 16 : 32, 40),
      children: [
        if (!isMobile) ...[
          const Row(
            children: [
              UiSkeletonBlock(width: 92, height: 15, radius: 7),
              Spacer(),
              UiSkeletonBlock(width: 72, height: 15, radius: 7),
              SizedBox(width: 76),
              UiSkeletonBlock(width: 72, height: 15, radius: 7),
            ],
          ),
          const SizedBox(height: 8),
        ],
        ...List.generate(
          isMobile ? 8 : 9,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ContactsRowSkeleton(
              kind: kind,
              shortName: index.isOdd,
              mobile: isMobile,
            ),
          ),
        ),
      ],
    );
  }
}

class _ContactsRowSkeleton extends StatelessWidget {
  const _ContactsRowSkeleton({
    required this.kind,
    required this.shortName,
    required this.mobile,
  });

  final ContactsRowsKind kind;
  final bool shortName;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 14 : 16,
        vertical: 12
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE9EEF6)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          UiSkeletonBlock(
            width: kind == ContactsRowsKind.agent ? 40 : 36,
            height: kind == ContactsRowsKind.agent ? 40 : 36,
            radius: kind == ContactsRowsKind.agent ? 12 : 999,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UiSkeletonBlock(
                  width: shortName ? 82 : 128,
                  height: 14,
                  radius: 7,
                ),
                const SizedBox(height: 8),
                UiSkeletonBlock(
                  width: kind == ContactsRowsKind.agent ? 184 : 132,
                  height: 12,
                  radius: 6,
                ),
              ],
            ),
          ),
          if (!mobile) ...[
            const SizedBox(width: 18),
            const UiSkeletonBlock(width: 76, height: 12, radius: 6),
            const SizedBox(width: 36),
            const UiSkeletonBlock(width: 68, height: 24, radius: 999),
          ],
        ],
      ),
    );
  }
}
