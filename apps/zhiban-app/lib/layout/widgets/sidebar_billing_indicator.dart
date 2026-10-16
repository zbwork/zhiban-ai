import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';

class SidebarBillingIndicator extends StatefulWidget {
  const SidebarBillingIndicator({
    super.key,
    required this.planName,
    required this.credits,
    required this.totalCredits,
    required this.isLowCredit,
    required this.onTap,
    this.collapsed = false,
  });

  final bool collapsed;
  final String planName;
  final int credits;
  final int totalCredits;
  final bool isLowCredit;
  final VoidCallback onTap;

  @override
  State<SidebarBillingIndicator> createState() =>
      _SidebarBillingIndicatorState();
}

class _SidebarBillingIndicatorState extends State<SidebarBillingIndicator> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) {
      return UiIconButton(
        icon: CupertinoIcons.star_fill,
        size: 44,
        iconSize: 21,
        color: const Color(0xFFD4A553),
        tooltip:
            '${widget.planName} · 剩余 ${_formatCredits(widget.credits)} 积分\n升级享受更多权益',
        onTap: widget.onTap,
      );
    }
    final fraction = widget.totalCredits > 0
        ? (widget.credits / widget.totalCredits).clamp(0.0, 1.0)
        : 0.0;
    final creditsText = _formatCredits(widget.credits);
    final totalCreditsText = _formatCredits(widget.totalCredits);
    final isCompactCreditText =
        creditsText.length <= 3 && totalCreditsText.length <= 3;
    final creditsFontSize = isCompactCreditText ? 16.0 : 21.0;
    final totalCreditsFontSize = isCompactCreditText ? 13.0 : 15.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 11),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFFFFCF6) : const Color(0xFFFFFAF0),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFF2E6D2)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFB8945E).withValues(alpha: 0.10),
                blurRadius: 16,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 27,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      CupertinoIcons.star_fill,
                      size: 13,
                      color: Color(0xFFD4A553),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: creditsText,
                                style: TextStyle(
                                  fontSize: creditsFontSize,
                                  height: 1,
                                  fontWeight: FontWeight.w900,
                                  color: const Color(0xFF4A3728),
                                ),
                              ),
                              TextSpan(
                                text: '/$totalCreditsText',
                                style: TextStyle(
                                  fontSize: totalCreditsFontSize,
                                  height: 1,
                                  fontWeight: FontWeight.w800,
                                  color: const Color(0xFF8C8178),
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFD5CCBF)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        widget.planName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B5B4A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 5,
                  child: LinearProgressIndicator(
                    value: fraction,
                    backgroundColor: const Color(0xFFF1E7D8),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFD8B985),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 11),
              const Row(
                children: [
                  Icon(
                    CupertinoIcons.rosette,
                    size: 14,
                    color: Color(0xFF8B7355),
                  ),
                  SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '升级享受更多权益',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF8B7355),
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 10,
                    color: Color(0xFFB5A899),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatCredits(num value) {
  final s = value.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final remaining = s.length - i;
    buf.write(s[i]);
    if (remaining > 1 && remaining % 3 == 1) buf.write(',');
  }
  return buf.toString();
}
