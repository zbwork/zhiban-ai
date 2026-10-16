import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';

/// 表单、详情等内容型弹框。
class UiContentDialog extends StatelessWidget {
  const UiContentDialog({
    super.key,
    required this.child,
    this.size = UiDialogSize.standard,
    this.maxHeight,
    this.minWidth = 320,
  });

  final Widget child;
  final UiDialogSize size;
  final double? maxHeight;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return UiDialogShell(
      size: size,
      maxHeight: maxHeight,
      minWidth: minWidth,
      child: child,
    );
  }
}
