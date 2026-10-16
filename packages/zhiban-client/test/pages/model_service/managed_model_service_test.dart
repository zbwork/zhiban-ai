import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/pages/model_service/widgets/provider_detail_panel.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_ui/widgets/ui_switch.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('BeeBridge复用原详情布局，真实密钥默认遮挡且眼睛可切换', (tester) async {
    var calls = 0;
    final keyReady = Completer<String>();
    const bee = CatalogProviderEntry(
        id: 'beebridge',
        name: 'BeeBridge',
        endpointType: AiEndpointType.openaiCompatible,
        baseUrl: 'https://api.beeaicloud.com/v1');
    await tester.pumpWidget(ProviderScope(
        overrides: [
          modelCatalogProvider.overrideWith((ref) async =>
              const ModelCatalog(providers: [bee], modelsByProviderId: {})),
          managedModelKeyProvider.overrideWith((ref) async {
            final status = await ref.watch(managedModelServiceProvider.future);
            return status.keyReady ? await keyReady.future : '';
          }),
          managedModelServiceProvider.overrideWith((ref) async {
            calls++;
            return ManagedModelService(
              status: calls == 1 ? 'needs_review' : 'ready',
              keyReady: calls > 1,
              models: calls == 1 ? [] : ['gpt-6-astra'],
              message: calls == 1 ? '需要重新检查' : '已初始化',
            );
          }),
        ],
        child: MaterialApp(
            builder: BotToastInit(),
            home: Scaffold(
                body: ProviderDetailPanel.draft(
                    catalogEntry: bee, onMaterialized: (_) {})))));
    await tester.pumpAndSettle();
    expect(find.text('还没有配置模型，点右上角「添加模型」新增'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('API 密钥'), findsOneWidget);
    expect(find.text('API 地址'), findsOneWidget);
    expect(find.text('获取模型列表'), findsOneWidget);
    expect(find.text('刷新状态'), findsNothing);
    expect(find.textContaining('当前成员接口返回'), findsNothing);
    expect(find.byType(UiSwitch), findsOneWidget);
    expect(find.text('企业模型服务'), findsNothing);
    await tester.tap(find.text('检测'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('检测成功，密钥可用'), findsNothing);
    expect(find.text('已初始化'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    keyReady.complete('synthetic-member-key');
    await tester.pumpAndSettle();
    expect(find.text('检测成功，密钥可用'), findsOneWidget);
    expect(find.text('已初始化'), findsNothing);
    expect(calls, 2);
    expect(find.text('已配置模型（0）'), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.every((field) => field.readOnly), isTrue);
    expect(fields.first.controller?.text, 'synthetic-member-key');
    expect(fields.first.obscureText, isTrue);
    await tester.tap(find.byTooltip('显示密钥'));
    await tester.pumpAndSettle();
    expect(
        tester.widgetList<TextField>(find.byType(TextField)).first.obscureText,
        isFalse);
    await tester.tap(find.byTooltip('隐藏密钥'));
    await tester.pumpAndSettle();
    expect(
        tester.widgetList<TextField>(find.byType(TextField)).first.obscureText,
        isTrue);
    expect(fields.last.controller?.text, 'https://api.beeaicloud.com/v1');
    expect(tester.widget<UiSwitch>(find.byType(UiSwitch)).onChanged, isNotNull);
    await tester.tap(find.text('获取模型列表'));
    await tester.pumpAndSettle();
    expect(find.text('添加模型'), findsOneWidget);
    expect(find.widgetWithText(TextField, '搜索模型...'), findsOneWidget);
    expect(calls, 2);
  });

  test('新会话不继承上一租户托管状态', () async {
    final first = ProviderContainer(overrides: [
      managedModelServiceProvider.overrideWith((ref) async =>
          const ManagedModelService(
              status: 'ready',
              keyReady: true,
              models: ['tenant-one-model'],
              message: 'one')),
    ]);
    expect((await first.read(managedModelServiceProvider.future)).keyReady,
        isTrue);
    first.dispose();
    final second = ProviderContainer(overrides: [
      managedModelServiceProvider.overrideWith((ref) async =>
          const ManagedModelService(
              status: 'disabled', keyReady: false, models: [], message: 'two')),
    ]);
    addTearDown(second.dispose);
    final state = await second.read(managedModelServiceProvider.future);
    expect(state.keyReady, isFalse);
    expect(state.models, isEmpty);
  });
}
