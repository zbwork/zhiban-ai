import 'package:flutter/widgets.dart';

/// Typography for short controls with a geometrically centered native caret.
class UiControlText {
  UiControlText._();

  static TextStyle? inputStyle(TextStyle? value) => _style(value, 1.3);

  static TextStyle? labelStyle(TextStyle? value) => _style(value, 4 / 3);

  static TextStyle? _style(TextStyle? value, double height) {
    if (value?.fontFamily != 'packages/zhiban_ui/HarmonyOS Sans SC') return value;
    // Bundled font: ascent 928, descent 244, units/em 1000; common CJK
    // glyph center ~380. Proportional leading centers it at line height
    // 0.380 / (928 / 1172 - 0.5) ≈ 1.30em. Digits differ by ~0.02em.
    // EditableText and short labels have separate line boxes. Labels round
    // to 4/3em to retain balanced raster bounds at 12/17px and 1.3x scaling.
    // Keep the line/caret centered instead of translating EditableText.
    return value!.copyWith(
      height: height,
      leadingDistribution: TextLeadingDistribution.proportional,
    );
  }
}
