import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/material.dart';

class SkillsDropdownField<T> extends StatelessWidget {
  const SkillsDropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabelBuilder,
    required this.onChanged,
    super.key,
  });

  final String label;
  final T value;
  final List<T> items;
  final String Function(T item) itemLabelBuilder;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return UiSelect<T>(
      options: items
          .map(
            (item) => UiSelectOption<T>(
              value: item,
              label: itemLabelBuilder(item),
            ),
          )
          .toList(),
      value: value,
      onChanged: onChanged,
      placeholder: label,
    );
  }
}
