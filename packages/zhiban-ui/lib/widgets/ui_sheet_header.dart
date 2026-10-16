import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:zhiban_ui/widgets/ui_icon_button.dart';

/// 内容型/表单型弹框的统一最大宽度。小确认框、小选择器、全屏创建弹框不适用。
const double kUiDialogMaxWidth = 640;

/// 通用面板/弹框 Header：左侧标题（可选副标题），右上角关闭按钮。
/// padding 由外部调用方决定。
class UiSheetHeader extends StatelessWidget {
  const UiSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
    this.closeEnabled = true,
    this.trailing,
  });

  final String title;
  final String? subtitle;

  /// 为 null 时不渲染关闭按钮。
  final VoidCallback? onClose;

  /// false 时关闭按钮置灰不可点（适用于保存中等场景）。
  final bool closeEnabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.3,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          trailing!,
          if (onClose != null) const SizedBox(width: 8),
        ],
        if (onClose != null)
          UiIconButton(
            icon: CupertinoIcons.xmark,
            tooltip: '关闭',
            onTap: onClose,
            enabled: closeEnabled,
          ),
      ],
    );
  }
}
