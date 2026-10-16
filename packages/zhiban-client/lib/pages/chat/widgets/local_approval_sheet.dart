import 'package:flutter/material.dart';
import 'local_approval_card.dart';

/// Mobile presentation only; decisions and busy/error handling stay in the card.
class LocalApprovalSheet extends StatelessWidget {
  const LocalApprovalSheet({
    super.key,
    required this.request,
    required this.onAnswer,
  });

  final Map<String, dynamic> request;
  final Future<void> Function(bool approved, String scope) onAnswer;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .85),
        child: SingleChildScrollView(
          child: LocalApprovalCard(
              request: request, onAnswer: onAnswer, inSheet: true),
        ),
      ),
    );
  }
}
