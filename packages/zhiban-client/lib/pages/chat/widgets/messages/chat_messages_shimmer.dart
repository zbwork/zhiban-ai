import 'dart:async';
import 'package:zhiban_ui/config/skeleton_config.dart';
import 'package:flutter/material.dart';

/// 会话消息区域首屏加载预留。
class ChatMessagesShimmer extends StatelessWidget {
  const ChatMessagesShimmer({super.key, required this.bottomContentInset});

  final double bottomContentInset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubbleWidth = constraints.maxWidth.clamp(0.0, 760.0);
        return ListView(
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomContentInset),
          children: [
            _AssistantSkeleton(maxWidth: maxBubbleWidth * 0.72),
            const SizedBox(height: 10),
            _UserSkeleton(maxWidth: maxBubbleWidth * 0.36),
            const SizedBox(height: 10),
            _AssistantSkeleton(maxWidth: maxBubbleWidth * 0.62, compact: true),
            const SizedBox(height: 10),
            _UserSkeleton(maxWidth: maxBubbleWidth * 0.48),
          ],
        );
      },
    );
  }
}

class _AssistantSkeleton extends StatelessWidget {
  const _AssistantSkeleton({required this.maxWidth, this.compact = false});

  final double maxWidth;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SkeletonAvatar(),
        const SizedBox(width: 8),
        Flexible(
          fit: FlexFit.loose,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: _SkeletonBubble(
              alignment: CrossAxisAlignment.start,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              children: [
                _SkeletonBlock(widthFactor: 0.46, height: 16, radius: 8),
                const SizedBox(height: 12),
                _SkeletonBlock(widthFactor: 1, height: 12, radius: 6),
                const SizedBox(height: 8),
                _SkeletonBlock(widthFactor: compact ? 0.58 : 0.86, height: 12),
                if (!compact) ...[
                  const SizedBox(height: 8),
                  _SkeletonBlock(widthFactor: 0.68, height: 12),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UserSkeleton extends StatelessWidget {
  const _UserSkeleton({required this.maxWidth});

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: _SkeletonBubble(
              color: SkeletonConfig.block,
              alignment: CrossAxisAlignment.end,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(6),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              children: const [
                _SkeletonBlock(widthFactor: 1, height: 14, radius: 7),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        const _SkeletonAvatar(),
      ],
    );
  }
}

class _SkeletonBubble extends StatelessWidget {
  const _SkeletonBubble({
    required this.children,
    required this.borderRadius,
    required this.alignment,
    this.color = SkeletonConfig.surface,
  });

  final List<Widget> children;
  final BorderRadius borderRadius;
  final CrossAxisAlignment alignment;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        border: Border.all(color: SkeletonConfig.block),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: alignment,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _SkeletonAvatar extends StatelessWidget {
  const _SkeletonAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: SkeletonConfig.block,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    required this.widthFactor,
    required this.height,
    this.radius = 6,
  });

  final double widthFactor;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: SkeletonConfig.block,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// Suppress transient loading hints during a fast local disk read. This never
/// delays ready content: the parent removes this widget as soon as it is ready.
class DeferredChatMessagesShimmer extends StatefulWidget {
  const DeferredChatMessagesShimmer({super.key, this.bottomContentInset = 0});
  final double bottomContentInset;
  @override
  State<DeferredChatMessagesShimmer> createState() => _DeferredShimmerState();
}

class _DeferredShimmerState extends State<DeferredChatMessagesShimmer> {
  Timer? _timer;
  bool _visible = false;
  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        debugPrint('[chat-first-frame] skeleton visible after 150ms');
        setState(() => _visible = true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _visible
      ? ChatMessagesShimmer(bottomContentInset: widget.bottomContentInset)
      : const SizedBox.expand();
}
