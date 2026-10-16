import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

class BillingStatusText extends StatelessWidget {
  const BillingStatusText({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

class RechargeAmountCard extends StatelessWidget {
  const RechargeAmountCard({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    const quickAmounts = [100, 200, 300];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE9EEF7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '充值金额',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF172033),
            ),
          ),
          const SizedBox(height: 14),
          UiInputField(
            controller: controller,
            hintText: '0.00',
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => onChanged(),
            textStyle: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w900,
              color: Color(0xFF172033),
            ),
            prefixText: '￥ ',
            prefixStyle: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w900,
              color: Color(0xFF172033),
            ),
            borderRadius: 14,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final amount in quickAmounts)
                OutlinedButton(
                  onPressed: enabled
                      ? () {
                          controller.text = amount.toString();
                          onChanged();
                        }
                      : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF172033),
                    side: const BorderSide(color: Color(0xFFE4E7EC)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 30,
                      vertical: 12,
                    ),
                  ),
                  child: Text('￥$amount'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class RechargePayMethodCard extends StatelessWidget {
  const RechargePayMethodCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE9EEF7)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFE8FAEF),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              CupertinoIcons.chat_bubble_text_fill,
              size: 20,
              color: Color(0xFF25D366),
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Text(
              '微信支付',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Color(0xFF172033),
              ),
            ),
          ),
          const Icon(
            CupertinoIcons.checkmark_circle_fill,
            size: 24,
            color: Color(0xFF165DFF),
          ),
        ],
      ),
    );
  }
}
