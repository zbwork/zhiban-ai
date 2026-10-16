import 'package:flutter/material.dart';

enum BillingCreditDetailTab { subscription, addOn, activity }

class BillingCreditDetailTabs extends StatelessWidget {
  const BillingCreditDetailTabs({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final BillingCreditDetailTab value;
  final ValueChanged<BillingCreditDetailTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final tab in BillingCreditDetailTab.values)
            Expanded(
              child: _TabButton(
                value: tab,
                label: switch (tab) {
                  BillingCreditDetailTab.subscription => '订阅积分',
                  BillingCreditDetailTab.addOn => '增购积分',
                  BillingCreditDetailTab.activity => '活动积分',
                },
                active: value == tab,
                onTap: () => onChanged(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.value,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final BillingCreditDetailTab value;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('billing-credit-detail-tab-${value.name}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: active ? const Color(0xFF101828) : const Color(0xFF667085),
          ),
        ),
      ),
    );
  }
}
