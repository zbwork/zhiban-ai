import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'ui_control_text.dart';
import 'ui_field_style.dart';

/// Validate every field, then reveal the first error in visual order.
bool validateUiForm(GlobalKey<FormState> key) {
  final invalid = key.currentState!.validateGranularly();
  if (invalid.isEmpty) return true;
  FocusManager.instance.primaryFocus?.unfocus();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final fields = invalid.where((field) => field.mounted).toList();
    double top(FormFieldState<Object?> field) {
      final box = field.context.findRenderObject() as RenderBox;
      return box.localToGlobal(Offset.zero).dy;
    }

    fields.sort((a, b) => top(a).compareTo(top(b)));
    if (fields.isEmpty) return;
    unawaited(Scrollable.ensureVisible(fields.first.context,
        alignment: 0.1, duration: const Duration(milliseconds: 200)));
  });
  return false;
}

/// Inline feedback for non-text fields, using the same error color as inputs.
class UiFormError extends StatelessWidget {
  const UiFormError(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(message!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error)),
      ),
    );
  }
}

class UiFormStyle {
  UiFormStyle._();

  static Color pageBackground(ColorScheme scheme) => Color.alphaBlend(
      scheme.onSurface.withValues(alpha: 0.025), scheme.surface);
}

/// 表单分组只负责视觉和留白，不持有字段或提交状态。
class UiFormSection extends StatelessWidget {
  const UiFormSection({
    super.key,
    this.title,
    this.subtitle,
    required this.child,
  });

  final String? title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: UiFieldStyle.enabledBorderColor(scheme)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Text(title!,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
          if (subtitle != null) ...[
            if (title != null) const SizedBox(height: 6),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: 13, height: 1.5, color: scheme.onSurfaceVariant)),
          ],
          if (title != null || subtitle != null) const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// 全宽表单操作，使用最小高度以容纳系统放大的文字。
class UiFormActions extends StatelessWidget {
  const UiFormActions({
    super.key,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.busy = false,
  });

  final String primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = UiControlText.inputStyle(
      TextStyle(
        fontFamily: theme.textTheme.bodyMedium?.fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: WidgetStatePropertyAll(textStyle),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    final secondary = secondaryLabel == null
        ? null
        : OutlinedButton(
            style: style.copyWith(
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.disabled)
                      ? scheme.onSurface.withValues(alpha: 0.38)
                      : scheme.onSurface),
              side: WidgetStatePropertyAll(
                  BorderSide(color: UiFieldStyle.enabledBorderColor(scheme))),
            ),
            onPressed: busy ? null : onSecondary,
            child: Text(secondaryLabel!, textAlign: TextAlign.center),
          );
    final primary = FilledButton(
      style: style,
      onPressed: busy ? null : onPrimary,
      child: busy
          ? const CupertinoActivityIndicator(radius: 10)
          : Text(primaryLabel, textAlign: TextAlign.center),
    );
    return LayoutBuilder(builder: (context, constraints) {
      double labelWidth(String label) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: textStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      // Equal-width actions switch to a column before either label is squeezed.
      final available = (constraints.maxWidth - 12) / 2 - 32;
      final stacked = secondary != null &&
          (labelWidth(primaryLabel) > available ||
              labelWidth(secondaryLabel!) > available);
      if (stacked) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              secondary,
              const SizedBox(height: 12),
              primary,
            ]);
      }
      return Row(children: [
        if (secondary != null) ...[
          Expanded(child: secondary),
          const SizedBox(width: 12),
        ],
        Expanded(child: primary),
      ]);
    });
  }
}

/// 全屏表单固定操作区。放在页面 Column 的滚动内容之后。
class UiFormFooter extends StatelessWidget {
  const UiFormFooter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
            top: BorderSide(color: UiFieldStyle.enabledBorderColor(scheme))),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: child,
      ),
    );
  }
}
