import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 内置表情选择器（零第三方依赖）。
///
/// 用法：`final e = await showEmojiPickerSheet(context); if (e != null) insert(e);`
/// 桌面端弹输入框上方的紧凑卡片，移动端弹底部 sheet；都返回选中的 emoji 字符。
Future<String?> showEmojiPickerSheet(BuildContext context) {
  final media = MediaQuery.of(context);
  if (media.size.width >= 720) {
    final renderObject = context.findRenderObject();
    final box = renderObject is RenderBox ? renderObject : null;
    final origin = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭表情选择器',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (dialogContext, _, __) {
        final size = MediaQuery.of(dialogContext).size;
        const margin = 16.0;
        final panelWidth = math.min(620.0, size.width - margin * 2);
        final panelHeight = math.min(380.0, size.height * 0.46);
        final rawLeft = origin.dx + 8;
        final left = rawLeft.clamp(margin, size.width - panelWidth - margin);
        final rawBottom = size.height - origin.dy + 8;
        final maxBottom = size.height - panelHeight - margin;
        final bottom = rawBottom.clamp(
          margin,
          math.max(margin, maxBottom)
        );
        return Stack(
          children: [
            Positioned(
              left: left.toDouble(),
              bottom: bottom.toDouble(),
              width: panelWidth,
              height: panelHeight,
              child: _EmojiPopover(
                child: _EmojiPickerBody(maxHeight: panelHeight),
              ),
            ),
          ],
        );
      },
    );
  }

  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => const _EmojiPickerBody(),
  );
}

/// 精选常用 emoji（约 120 个），分 4 组。点选即插入，不做搜索/肤色。
const Map<String, List<String>> _emojiGroups = {
  '常用': [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😊',
    '😍',
    '😘',
    '😎',
    '🤩',
    '🥳',
    '😇',
    '🙂',
    '😉',
    '😌',
    '😋',
    '😜',
    '🤗',
    '🤔',
    '🫡',
    '🤝',
  ],
  '情绪': [
    '😅',
    '😆',
    '😴',
    '😪',
    '😮',
    '😯',
    '😲',
    '🥺',
    '😢',
    '😭',
    '😤',
    '😠',
    '😡',
    '🤯',
    '😱',
    '😨',
    '😰',
    '😳',
    '🙄',
    '😬',
    '😶',
    '😐',
    '😑',
    '🤐',
    '🫥',
    '😵',
    '🤥',
    '😏',
    '😒',
    '🥲',
  ],
  '手势': [
    '👍',
    '👎',
    '👌',
    '🤌',
    '✌️',
    '🤞',
    '🫰',
    '🤟',
    '🤙',
    '👏',
    '🙌',
    '🙏',
    '💪',
    '👋',
    '✋',
    '🤚',
    '👆',
    '👇',
    '👉',
    '👈',
    '✊',
    '👊',
    '🤛',
    '🤜',
    '☝️',
    '✍️',
  ],
  '符号/物件': [
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🤍',
    '💔',
    '💯',
    '✨',
    '🎉',
    '🎊',
    '🔥',
    '⭐',
    '🌟',
    '⚡',
    '💡',
    '✅',
    '❌',
    '❓',
    '❗',
    '⚠️',
    '🆗',
    '🎁',
    '📌',
    '📎',
    '📅',
    '📞',
    '💬',
    '☕',
    '🍺',
    '🍕',
    '🌹',
    '🚀',
    '⏰',
  ],
};

/// 移动端输入栏下方内嵌面板版本——直接回调，不依赖 Navigator。
class EmojiPickerInlinePanel extends StatelessWidget {
  const EmojiPickerInlinePanel({super.key, required this.onEmojiSelected});
  final ValueChanged<String> onEmojiSelected;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      color: Colors.white,
      height: 260,
      child: ListView(
        padding: EdgeInsets.fromLTRB(12, 10, 12, 12 + bottomPad),
        children: [
          for (final entry in _emojiGroups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
              child: Text(
                entry.key,
                style: const TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
              ),
            ),
            Wrap(
              children: [
                for (final e in entry.value)
                  _EmojiCell(emoji: e, onTap: () => onEmojiSelected(e)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EmojiPickerBody extends StatelessWidget {
  const _EmojiPickerBody({this.maxHeight});

  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight ?? height * 0.5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                children: [
                  for (final entry in _emojiGroups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                      child: Text(
                        entry.key,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF98A2B3),
                        ),
                      ),
                    ),
                    Wrap(
                      children: [
                        for (final e in entry.value)
                          _EmojiCell(
                            emoji: e,
                            onTap: () => Navigator.of(context).pop(e),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmojiPopover extends StatelessWidget {
  const _EmojiPopover({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _EmojiCell extends StatefulWidget {
  const _EmojiCell({required this.emoji, required this.onTap});
  final String emoji;
  final VoidCallback onTap;

  @override
  State<_EmojiCell> createState() => _EmojiCellState();
}

class _EmojiCellState extends State<_EmojiCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFFF2F3F5) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
}
