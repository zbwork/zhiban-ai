import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CopyWidget extends StatefulWidget {
  final String content;
  final String tooltip;
  final String copiedTooltip;
  final String copiedMessage;

  /// 图标尺寸；点击热区 = iconSize + 内边距(4×2) + 2。默认保持历史尺寸 18。
  final double iconSize;

  const CopyWidget({
    super.key,
    required this.content,
    this.tooltip = '复制',
    this.copiedTooltip = '已复制',
    this.copiedMessage = '已复制',
    this.iconSize = 18,
  });

  @override
  CopyWidgetState createState() => CopyWidgetState();
}

class CopyWidgetState extends State<CopyWidget> {
  bool isActive = false;

  @override
  Widget build(BuildContext context) {
    final boxSize = widget.iconSize + 10;
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeIn,
        switchOutCurve: Curves.easeOut,
        child: !isActive
            ? OptionWrapper(
                key: const ValueKey('doc'),
                icon: CupertinoIcons.doc_on_doc,
                iconSize: widget.iconSize,
                tooltip: widget.tooltip,
                onTap: () {
                  if (widget.content.trim().isEmpty) return;
                  Clipboard.setData(ClipboardData(text: widget.content));
                  BotToast.showText(text: widget.copiedMessage);
                  setState(() {
                    isActive = true;
                  });
                  Future.delayed(const Duration(seconds: 3), () {
                    if (mounted) {
                      setState(() {
                        isActive = false;
                      });
                    }
                  });
                },
              )
            : OptionWrapper(
                key: const ValueKey('check'),
                icon: CupertinoIcons.check_mark,
                iconSize: widget.iconSize,
                tooltip: widget.copiedTooltip,
                onTap: () {
                  // 点击后不做任何操作
                },
                isActive: true,
              ),
      ),
    );
  }
}

class OptionWrapper extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool isActive;
  final double iconSize;
  const OptionWrapper({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.isActive = false,
    this.iconSize = 18,
  });

  @override
  Widget build(context) {
    // 点击后已经有 BotToast 的"已复制"提示（见 CopyWidget.onTap），这里不再叠加
    // Tooltip，避免同时出现两个"已复制"气泡。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Icon(
          icon,
          size: iconSize,
          color: isActive ? Theme.of(context).primaryColor : const Color(0xff999999),
        ),
      ),
    );
  }
}
