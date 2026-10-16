import 'package:flutter/material.dart';

const _brandBlue = Color(0xFF155EEF);
const _muted = Color(0xFF667085);
const _border = Color(0xFFE8EDF5);

class BillingCycleSwitch extends StatelessWidget {
  const BillingCycleSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F5FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BillingCycleOption(
            value: 'monthly',
            label: '按月付',
            active: value == 'monthly',
            onTap: () => onChanged('monthly'),
          ),
          _BillingCycleOption(
            value: 'yearly',
            label: '按年付',
            active: value == 'yearly',
            onTap: () => onChanged('yearly'),
          ),
        ],
      ),
    );
  }
}

class _BillingCycleOption extends StatelessWidget {
  const _BillingCycleOption({
    required this.value,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String value;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('billing-cycle-option-$value'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: _brandBlue.withValues(alpha: 0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: active ? _brandBlue : _muted,
          ),
        ),
      ),
    );
  }
}
