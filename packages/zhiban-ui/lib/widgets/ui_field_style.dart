import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:flutter/material.dart';

class UiFieldStyle {
  UiFieldStyle._();

  static double get defaultHeight => PlatformUtils.isMobile ? 36.0 : 40.0;
  static double get defaultBorderRadius => PlatformUtils.isMobile ? 8.0 : 10.0;

  /// 用统一算法（目标高度减去内容自身高度，再除二分给上下）反推 vertical
  /// padding；[contentHeight] 是调用方自己内容撑出来的高度（文字行高、图标
  /// 高度取较大值等），不同组件的内容结构不一样，必须各自传自己的真实值，
  /// 不能共用同一个数字——同一个 target 高度下，UiSelect 的 Row(文字+22px
  /// 图标) 跟 UiInputField 的 TextField（受 InputDecorator 内部密度偏移等
  /// 因素影响）算出来的实际内容高度本来就不同。
  static double verticalPaddingForHeight(
    double height, {
    double contentHeight = 16,
  }) =>
      (height - contentHeight) / 2;

  static Color defaultBorderColor(ColorScheme scheme) => scheme.outlineVariant;
  static Color enabledBorderColor(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: 0.5);
  static Color disabledBorderColor(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: 0.4);
  static Color hoverBorderColor(ColorScheme scheme) =>
      enabledBorderColor(scheme);
  static Color focusBorderColor(ColorScheme scheme) => PlatformUtils.isMobile
      ? enabledBorderColor(scheme)
      : scheme.primary.withValues(alpha: 0.45);
  static Color errorBorderColor(ColorScheme scheme) => scheme.error;

  /// 渲染字段 label；约定以 "*" 结尾表示必填，星号单独用 error 色高亮。
  static Widget labelText(String text, TextStyle style, ColorScheme scheme) {
    if (!text.endsWith('*')) return Text(text, style: style);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: text.substring(0, text.length - 1)),
          TextSpan(text: '*', style: style.copyWith(color: scheme.error)),
        ],
      ),
    );
  }

  static Color defaultFillColor(ColorScheme scheme) => scheme.surface;
  static Color hoverFillColor(ColorScheme scheme) => defaultFillColor(scheme);
  static Color disabledFillColor(ColorScheme scheme) =>
      scheme.onSurface.withValues(alpha: 0.04);
}
