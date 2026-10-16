import 'package:flutter/widgets.dart';

/// 下拉选择选项数据模型
class SelectOption<T> {
  final T value;
  final String label;
  final IconData? icon;

  const SelectOption({
    required this.value,
    required this.label,
    this.icon
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectOption<T> &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}
