import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/pages/settings/widgets/billing_cycle_switch.dart';

void main() {
  testWidgets('billing cycle selection switches monthly and yearly', (
    tester,
  ) async {
    var value = 'monthly';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BillingCycleSwitch(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    for (final (label, expected) in [('按年付', 'yearly'), ('按月付', 'monthly')]) {
      await tester.tap(find.text(label));
      await tester.pump();
      expect(value, expected);
      expect(
        tester
            .widget<BillingCycleSwitch>(find.byType(BillingCycleSwitch))
            .value,
        expected,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
