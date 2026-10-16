import 'package:flutter/material.dart';

/// Persistent provenance footer, separate from selectable/generated content.
class UiAiGeneratedLabel extends StatelessWidget {
  const UiAiGeneratedLabel({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'AI 生成',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
      ),
    );
  }
}
