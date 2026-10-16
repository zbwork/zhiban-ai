import 'package:flutter/material.dart';
import 'package:zhiban_client/models/billing_models.dart';

/// Keep the usage column compact; hover or long-press reveals its components.
class BillingUsageTooltip extends StatelessWidget {
  const BillingUsageTooltip(
      {super.key, required this.event, required this.child});

  final BillingUsageEvent event;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (event.resourceType != 'llm' && !event.isBeeBridge) return child;
    return Tooltip(
      message: event.tokenDetailLabel,
      waitDuration: const Duration(milliseconds: 300),
      triggerMode: TooltipTriggerMode.longPress,
      child: child,
    );
  }
}
