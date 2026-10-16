import 'package:flutter/material.dart';

/// 桌面侧栏边缘把手：弱化默认态，hover / focus 时再提高可见度。
abstract final class UiSidebarToggleStyle {
  static Color fill(ColorScheme scheme, {required bool highlighted}) {
    if (scheme.brightness == Brightness.light) {
      return const Color(0xFF6B9BD2)
          .withValues(alpha: highlighted ? 0.16 : 0.08);
    }
    return Color.alphaBlend(
      scheme.primary.withValues(alpha: highlighted ? 0.2 : 0.1),
      scheme.surfaceContainerLow,
    );
  }

  static Color foreground(ColorScheme scheme, {required bool highlighted}) {
    if (scheme.brightness == Brightness.light) {
      return highlighted ? const Color(0xFF4F6786) : const Color(0xFF6B7F98);
    }
    return highlighted ? scheme.onSurface : scheme.onSurfaceVariant;
  }
}
