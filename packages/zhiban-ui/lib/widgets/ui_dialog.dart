import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'ui_form.dart';
import 'ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

/// 通用确认弹框（Shadcn AlertDialog 风格）。
///
/// 竖向布局：标题 → 描述 → 底部右对齐按钮组。
/// 通过 [showUiConfirmDialog] 调用，返回 `true` 表示用户确认。
class UiConfirmDialog extends StatelessWidget {
  const UiConfirmDialog({
    super.key,
    required this.title,
    this.description,
    this.cancelLabel = '取消',
    this.confirmLabel = '确定',
    this.danger = false,
    this.showCancelAction = true,
  });

  final String title;
  final String? description;
  final String cancelLabel;
  final String confirmLabel;
  final bool danger;
  final bool showCancelAction;

  @override
  Widget build(BuildContext context) {
    final confirmColor = danger
        ? const Color(0xFFDC2626)
        : Theme.of(context).colorScheme.primary;

    return UiDialogShell(
      size: UiDialogSize.compact,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF101828),
                height: 1.4,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 6),
              Text(
                description!,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF667085),
                  height: 1.6,
                ),
              ),
            ],
            const SizedBox(height: 24),
            // Footer
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (showCancelAction) ...[
                  _OutlineBtn(
                    label: cancelLabel,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                ],
                _FilledBtn(
                  label: confirmLabel,
                  color: confirmColor,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 通用输入弹框（Shadcn Dialog 风格）。
/// 通过 [showUiInputDialog] 调用，返回用户输入的字符串，取消时返回 `null`。
class UiInputDialog extends StatefulWidget {
  const UiInputDialog({
    super.key,
    required this.title,
    this.description,
    this.initialValue = '',
    this.hintText,
    this.confirmLabel = '确定',
    this.cancelLabel = '取消',
    this.maxLength,
    this.validator,
  });

  final String title;
  final String? description;
  final String initialValue;
  final String? hintText;
  final String confirmLabel;
  final String cancelLabel;
  final int? maxLength;
  final String? Function(String value)? validator;

  @override
  State<UiInputDialog> createState() => _UiInputDialogState();
}

class _UiInputDialogState extends State<UiInputDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _controller.text.trim();
    final error = widget.validator?.call(value);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return UiDialogShell(
      size: UiDialogSize.compact,
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(PlatformUtils.isMobile ? 20 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UiSheetHeader(
                title: widget.title,
                subtitle: widget.description,
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 16),
              UiInputField(
                controller: _controller,
                hintText: widget.hintText ?? '',
                autofocus: true,
                maxLength: widget.maxLength,
                onChanged: (_) {
                  if (_errorText != null) setState(() => _errorText = null);
                },
                onSubmitted: (_) => _confirm(),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  _errorText!,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
                ),
              ],
              const SizedBox(height: 20),
              if (PlatformUtils.isMobile)
                UiFormActions(
                  primaryLabel: widget.confirmLabel,
                  onPrimary: _confirm,
                  secondaryLabel: widget.cancelLabel,
                  onSecondary: () => Navigator.of(context).pop(),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _OutlineBtn(
                      label: widget.cancelLabel,
                      onTap: () => Navigator.of(context).pop(null),
                    ),
                    const SizedBox(width: 8),
                    _FilledBtn(
                      label: widget.confirmLabel,
                      color: Theme.of(context).colorScheme.primary,
                      onTap: _confirm,
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

// ─── 内部按钮组件 ───────────────────────────────────────────────

class _OutlineBtn extends StatefulWidget {
  const _OutlineBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_OutlineBtn> createState() => _OutlineBtnState();
}

class _OutlineBtnState extends State<_OutlineBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFF9FAFB) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  _hovered ? const Color(0xFFD0D5DD) : const Color(0xFFE4E7EC),
            ),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF344054),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilledBtn extends StatefulWidget {
  const _FilledBtn({
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_FilledBtn> createState() => _FilledBtnState();
}

class _FilledBtnState extends State<_FilledBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color:
                _hovered ? widget.color.withValues(alpha: 0.88) : widget.color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 公共 helper ──────────────────────────────────────────────

/// 显示确认弹框，返回 `true` 表示用户确认，`false`/`null` 表示取消。
Future<bool> showUiConfirmDialog(
  BuildContext context, {
  required String title,
  String? description,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
  bool danger = false,
  bool useRootNavigator = true,
  bool waitForRemoval = false,
}) async {
  Future<dynamic>? removed;
  final result = await showDialog<bool>(
    context: context,
    useRootNavigator: useRootNavigator,
    builder: (dialogContext) {
      removed = ModalRoute.of(dialogContext)?.completed;
      return UiConfirmDialog(
        title: title,
        description: description,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        danger: danger,
      );
    },
  );
  if (waitForRemoval) await removed;
  return result == true;
}

/// 显示输入弹框，返回用户输入的字符串；取消时返回 `null`。
Future<String?> showUiInputDialog(
  BuildContext context, {
  required String title,
  String? description,
  String initialValue = '',
  String? hintText,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  int? maxLength,
  String? Function(String value)? validator,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => UiInputDialog(
      title: title,
      description: description,
      initialValue: initialValue,
      hintText: hintText,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      maxLength: maxLength,
      validator: validator,
    ),
  );
}

Future<void> showUiNoticeDialog(
  BuildContext context, {
  required String title,
  String? description,
  String confirmLabel = '我知道了',
  bool barrierDismissible = true,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (_) => UiConfirmDialog(
      title: title,
      description: description,
      confirmLabel: confirmLabel,
      showCancelAction: false,
    ),
  );
}
