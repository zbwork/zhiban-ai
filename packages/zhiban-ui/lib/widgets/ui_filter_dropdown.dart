import 'package:flutter/material.dart';
import 'ui_dropdown_menu.dart';

/// Compact filter with a solid arrow that changes direction without rotation.
class UiFilterDropdown<T> extends StatefulWidget {
  const UiFilterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.alignment = Alignment.center,
  });

  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final Alignment alignment;

  @override
  State<UiFilterDropdown<T>> createState() => _UiFilterDropdownState<T>();
}

class _UiFilterDropdownState<T> extends State<UiFilterDropdown<T>> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return UiDropdownMenu<T>(
      activeValue: widget.value,
      items: [
        for (final entry in widget.items.entries)
          UiDropdownMenuItem(value: entry.key, label: entry.value),
      ],
      onSelected: widget.onChanged,
      onExpandedChanged: (expanded) => setState(() => _expanded = expanded),
      child: Semantics(
        button: true,
        child: Container(
          height: 48,
          alignment: widget.alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: _expanded ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Icon(
                _expanded
                    ? Icons.arrow_drop_up_rounded
                    : Icons.arrow_drop_down_rounded,
                size: 22,
                color: _expanded
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
