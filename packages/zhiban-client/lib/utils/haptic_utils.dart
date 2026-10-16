import 'package:flutter/services.dart';

class HapticUtils {
  static Future<void> lightImpact() => HapticFeedback.lightImpact();

  static Future<void> mediumImpact() => HapticFeedback.mediumImpact();

  static Future<void> heavyImpact() => HapticFeedback.heavyImpact();

  static Future<void> selectionClick() => HapticFeedback.selectionClick();
}
