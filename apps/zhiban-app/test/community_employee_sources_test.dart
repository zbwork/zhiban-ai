import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/pages/digital_employee/digital_employee_page.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';
import 'package:zhiban_client/pages/server_connection/community_market_providers.dart';
import 'package:zhiban_core/chat/chat_models.dart';

AgentItem _agent(String name) => AgentItem.fromJson({
      'uuid': 'same-id-in-different-origins',
      'name': name,
      'status': 'published',
      'intro': '分类回归',
    });

class _ServerCatalog extends OpenClawDigitalEmployeeService {
  bool fail = false;
  @override
  Future<DigitalEmployeeCatalog> listCatalog({String keyword = ''}) async {
    if (fail) throw StateError('offline server directory');
    final mine = _agent('我的验收员工');
    final organization = _agent('组织验收员工');
    return DigitalEmployeeCatalog(
      personal: [
        if (mine.name.contains(keyword))
          DigitalEmployeeCatalogItem.personal(mine),
      ],
      enterprise: [
        if (organization.name.contains(keyword))
          DigitalEmployeeCatalogItem(
            agent: organization,
            source: DigitalEmployeeCatalogSource.enterprise,
          ),
      ],
    );
  }
}

void main() {
  setUp(() {
    AppConfig.serverApiUrl = 'http://127.0.0.1:38080/api/agent-bus/v1';
  });
  tearDown(() => AppConfig.serverApiUrl = null);

  testWidgets('default gallery shows real organization and personal sources',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        digitalEmployeeServiceProvider.overrideWithValue(_ServerCatalog()),
        communityEmployeesProvider
            .overrideWith((ref) async => [_agent('官方验收模板')]),
      ],
      child: const MaterialApp(home: DigitalEmployeePage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('公共广场'), findsNothing);
    expect(find.text('当前服务器'), findsNothing);
    expect(find.byType(AgentCard), findsNWidgets(3));
    expect(find.text('新建数字员工'), findsOneWidget);

    await tester.tap(find.text('组织'));
    await tester.pumpAndSettle();
    expect(find.text('组织验收员工'), findsOneWidget);
    expect(find.byType(AgentCard), findsOneWidget);
    expect(tester.widget<AgentCard>(find.byType(AgentCard)).canEdit, isFalse);
    await tester.tap(find.text('组织验收员工'));
    await tester.pumpAndSettle();
    expect(find.text('去聊天'), findsOneWidget);
    expect(find.text('添加到当前服务器'), findsNothing);
    Navigator.of(tester.element(find.text('数字员工详情'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('我的验收员工'), findsOneWidget);
    expect(find.byType(AgentCard), findsOneWidget);
    expect(tester.widget<AgentCard>(find.byType(AgentCard)).canEdit, isTrue);

    await tester.tap(find.text('官方'));
    await tester.pumpAndSettle();
    expect(find.text('官方验收模板'), findsOneWidget);
    expect(tester.widget<AgentCard>(find.byType(AgentCard)).canEdit, isFalse);
    await tester.tap(find.text('官方验收模板'));
    await tester.pumpAndSettle();
    expect(find.text('添加到当前服务器'), findsOneWidget);
    expect(find.text('去聊天'), findsNothing);
    await tester.tap(find.text('添加到当前服务器'));
    await tester.pumpAndSettle();
    expect(find.text('添加'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我的');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byType(AgentCard), findsOneWidget);
    expect(find.text('我的验收员工'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '官方');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byType(AgentCard), findsOneWidget);
    expect(find.text('官方验收模板'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('public directory failure preserves server sources and retry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var fail = true;
    await tester.pumpWidget(ProviderScope(
      retry: (_, __) => null,
      overrides: [
        digitalEmployeeServiceProvider.overrideWithValue(_ServerCatalog()),
        communityEmployeesProvider.overrideWith((ref) async {
          if (fail) throw StateError('offline public directory');
          return [_agent('恢复的官方模板')];
        }),
      ],
      child: const MaterialApp(home: DigitalEmployeePage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('公共数字员工加载失败，请检查网络后重试'), findsOneWidget);
    await tester.tap(find.text('组织'));
    await tester.pumpAndSettle();
    expect(find.text('组织验收员工'), findsOneWidget);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('我的验收员工'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试公共目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('官方'));
    await tester.pumpAndSettle();
    expect(find.text('恢复的官方模板'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('server directory failure preserves public templates and retry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _ServerCatalog()..fail = true;
    await tester.pumpWidget(ProviderScope(
      retry: (_, __) => null,
      overrides: [
        digitalEmployeeServiceProvider.overrideWithValue(service),
        communityEmployeesProvider
            .overrideWith((ref) async => [_agent('官方验收模板')]),
      ],
      child: const MaterialApp(home: DigitalEmployeePage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('服务器数字员工加载失败，请检查连接后重试'), findsOneWidget);
    expect(find.text('官方验收模板'), findsOneWidget);
    await tester.tap(find.text('组织'));
    await tester.pumpAndSettle();
    expect(find.text('服务器数字员工加载失败，请检查连接后重试'), findsOneWidget);
    service.fail = false;
    await tester.tap(find.text('重试服务器目录'));
    await tester.pumpAndSettle();
    expect(find.text('组织验收员工'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
