import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/model_service/model_service_page.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/widgets/provider_detail_panel.dart';
import 'package:zhiban_ui/themes/app_theme.dart';

void main() {
  testWidgets('key link keeps brand blue inside neutral model service theme',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ModelServicePageTheme(
            child: ProviderDetailPanel.draft(
              catalogEntry: const CatalogProviderEntry(
                id: 'example',
                name: 'Example',
                endpointType: AiEndpointType.openaiCompatible,
                baseUrl: 'https://example.com/v1',
                websiteUrl: 'https://example.com/',
              ),
              onMaterialized: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final link = find.text('获取密钥');
    final theme = Theme.of(tester.element(link));
    expect(theme.colorScheme.primary, isNot(theme.primaryColor));
    expect(tester.widget<Text>(link).style?.color, theme.primaryColor);
    expect(theme.primaryColor, AppTheme.brandColor);
  });
}
