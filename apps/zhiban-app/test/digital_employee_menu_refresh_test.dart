import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:nexwork/pages/digital_employee/digital_employee_page.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';

class _CountingCatalog extends DigitalEmployeeCatalogNotifier {
  int refreshCalls = 0;

  @override
  Future<DigitalEmployeeCatalog> build() async => const DigitalEmployeeCatalog(
        personal: [],
        enterprise: [],
      );

  @override
  Future<void> refresh({
    AgentItem? preservePersonalAgent,
    bool keepPreviousOnError = false,
  }) async {
    refreshCalls++;
    state = const AsyncData(DigitalEmployeeCatalog(
      personal: [],
      enterprise: [],
    ));
  }
}

void main() {
  testWidgets('entering digital employee menu refreshes cached catalog',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final notifier = _CountingCatalog();
    final container = ProviderContainer(overrides: [
      digitalEmployeeCatalogProvider.overrideWith(() => notifier),
    ]);
    addTearDown(container.dispose);
    await container.read(digitalEmployeeCatalogProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DigitalEmployeePage()),
      ),
    );
    await tester.pump();

    expect(notifier.refreshCalls, 1);
  });
}
