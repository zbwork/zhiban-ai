import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_provider_dialog.dart';
import 'package:zhiban_client/pages/model_service/widgets/request_config_dialog.dart';

void main() {
  testWidgets('custom provider dialog does not expose protocol selection',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddProviderDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('添加自定义服务商'), findsOneWidget);
    expect(find.text('API 地址'), findsOneWidget);
    expect(find.text('协议类型'), findsNothing);
  });

  testWidgets('custom provider dialog validates required fields inline',
      (tester) async {
    NewProviderInput? submittedInput;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              submittedInput = await showAddProviderDialog(context);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pump();

    expect(find.text('请输入服务商名称'), findsOneWidget);
    expect(find.text('请输入 API 地址'), findsOneWidget);
    expect(find.text('添加自定义服务商'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Example Provider');
    await tester.pump();

    expect(find.text('请输入服务商名称'), findsNothing);
    expect(find.text('请输入 API 地址'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).last,
      'https://api.example.com/v1',
    );
    await tester.pump();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(submittedInput?.name, 'Example Provider');
    expect(submittedInput?.baseUrl, 'https://api.example.com/v1');
    expect(find.text('添加自定义服务商'), findsNothing);
  });

  testWidgets('request config dialog does not expose multi-endpoint controls',
      (tester) async {
    const provider = AiProviderConfig(
      id: 'provider-1',
      name: 'Example',
      baseUrl: 'https://api.example.com/v1',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRequestConfigDialog(
                context,
                provider: provider,
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

    expect(find.text('请求配置'), findsOneWidget);
    expect(find.text('图像生成 Base URL'), findsOneWidget);
    expect(find.text('添加端点'), findsNothing);
    expect(find.text('设为默认'), findsNothing);
  });
}
