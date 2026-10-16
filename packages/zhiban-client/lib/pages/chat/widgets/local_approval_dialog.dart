import 'package:flutter/material.dart';
import 'local_approval_card.dart';

/// Desktop surface; approval decisions remain in the shared card.
class LocalApprovalDialog extends StatelessWidget {
  const LocalApprovalDialog({
    super.key,
    required this.request,
    required this.onAnswer,
  });

  final Map<String, dynamic> request;
  final Future<void> Function(bool approved, String scope) onAnswer;

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: LocalApprovalCard(
              request: request,
              onAnswer: onAnswer,
              inDialog: true,
            ),
          ),
        ),
      );
}
