import 'package:flutter/material.dart';
import 'package:zhiban_ui/widgets/ui_field_style.dart';

import '../local_workspace/services/local_workspace_store.dart';

const roundtableControlHeight = 40.0;
const roundtableControlRadius = 10.0;
const roundtableComposerGap = 8.0;
const roundtableQuestionHint = '向圆桌专家提问…';

const _roundtableControlShape = WidgetStatePropertyAll<OutlinedBorder>(
  RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(roundtableControlRadius)),
  ),
);

const roundtableTextControlStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, roundtableControlHeight)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
  shape: _roundtableControlShape,
);

const roundtableIconControlStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size.square(roundtableControlHeight)),
  fixedSize: WidgetStatePropertyAll(Size.square(roundtableControlHeight)),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
  iconSize: WidgetStatePropertyAll(18),
  shape: _roundtableControlShape,
);

class RoundtableExpertControl extends StatelessWidget {
  const RoundtableExpertControl({
    super.key,
    required this.experts,
    required this.onPressed,
    this.avatarBuilder,
  });

  final List<LocalRow> experts;
  final VoidCallback? onPressed;
  final Widget Function(LocalRow, double)? avatarBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const avatarSize = 20.0;
    return FilledButton(
      onPressed: onPressed,
      style: roundtableTextControlStyle.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? scheme.surfaceContainerLow
                : scheme.surfaceContainerLowest),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? scheme.onSurface.withValues(alpha: .38)
                : scheme.onSurfaceVariant),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? UiFieldStyle.focusBorderColor(scheme)
                : UiFieldStyle.enabledBorderColor(scheme),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final expert in experts.take(3))
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 2),
              child: ExcludeSemantics(
                child: avatarBuilder?.call(expert, avatarSize) ??
                    CircleAvatar(
                      radius: avatarSize / 2,
                      child: Text(
                        '${expert['name'] ?? ''}'
                                .trim()
                                .characters
                                .firstOrNull ??
                            '博',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
              ),
            ),
          if (experts.isNotEmpty) const SizedBox(width: 4),
          Text(experts.isEmpty ? '选择专家' : '${experts.length} 位专家'),
        ],
      ),
    );
  }
}
