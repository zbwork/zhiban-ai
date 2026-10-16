import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';

/// 候选选择类弹框。业务页面只选择尺寸等级并提供内容。
class UiPickerDialog extends StatelessWidget {
  const UiPickerDialog({
    super.key,
    required this.child,
    this.size = UiDialogSize.standard,
    this.maxHeight,
    this.minWidth = 320,
  }) : fullScreen = false;

  const UiPickerDialog.fullScreen({
    super.key,
    required this.child,
  })  : size = UiDialogSize.wide,
        maxHeight = null,
        minWidth = 0,
        fullScreen = true;

  final Widget child;
  final UiDialogSize size;
  final double? maxHeight;
  final double minWidth;
  final bool fullScreen;

  @override
  Widget build(BuildContext context) {
    if (fullScreen) {
      return Dialog.fullscreen(
        backgroundColor: Colors.white,
        child: child,
      );
    }
    return UiDialogShell(
      size: size,
      maxHeight: maxHeight,
      minWidth: minWidth,
      child: child,
    );
  }
}
