import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_model_dialog.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('model id tooltip is left-anchored with a centered line box',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const provider = AiProviderConfig(
      id: 'provider-1',
      name: 'Example',
      baseUrl: 'https://api.example.com/v1',
    );
    const catalogModel = CatalogModelEntry(
      providerId: 'provider-1',
      modelId: 'deepseek-v3.1',
      displayName: 'DeepSeek V3.1',
      groupName: 'DeepSeek',
      capabilities: {},
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddModelDialog(
                context,
                provider: provider,
                endpointType: AiEndpointType.openaiCompatible,
                catalogModels: const [catalogModel],
                apiKey: '',
                baseUrl: provider.baseUrl,
                ensureLocalId: () async => provider.id,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final titleFinder = find.text('DeepSeek V3.1');
    final tooltipFinder = find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == 'deepseek-v3.1',
    );
    expect(titleFinder, findsOneWidget);
    expect(tooltipFinder, findsOneWidget);

    final tooltip = tester.widget<Tooltip>(tooltipFinder);
    expect(tooltip.textAlign, TextAlign.left);
    expect(tooltip.textStyle?.height, 1);
    expect(
      tooltip.textStyle?.leadingDistribution,
      TextLeadingDistribution.even,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(titleFinder));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    final messageFinder = find.text('deepseek-v3.1');
    expect(messageFinder, findsOneWidget);
    final titleLeft = tester.getTopLeft(titleFinder).dx;
    final tooltipTextLeft = tester.getTopLeft(messageFinder).dx;
    expect(tooltipTextLeft, lessThan(titleLeft + 40));
  });
}
