import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';
import 'package:zhiban_client/pages/server_connection/community_employee_gallery.dart';
import 'package:zhiban_client/pages/server_connection/community_market_providers.dart';

class _PendingCatalog extends DigitalEmployeeCatalogNotifier {
  @override
  Future<DigitalEmployeeCatalog> build() =>
      Completer<DigitalEmployeeCatalog>().future;
}

class _ReadyOrganizationCatalog extends DigitalEmployeeCatalogNotifier {
  @override
  Future<DigitalEmployeeCatalog> build() async => DigitalEmployeeCatalog(
        personal: const [],
        enterprise: [
          DigitalEmployeeCatalogItem(
            agent: AgentItem(
              agentId: 'organization-employee',
              name: '组织员工',
              description: '已加载的组织员工',
              avatarUrl: '',
              skills: const [],
              status: 'published',
              isDefault: false,
              syncStatus: 'synced',
              lastSyncedAt: null,
            ),
            source: DigitalEmployeeCatalogSource.enterprise,
          )
        ],
      );

  @override
  Future<void> refresh(
      {AgentItem? preservePersonalAgent,
      bool keepPreviousOnError = false}) async {}
}

void main() {
  for (final fail in [false, true]) {
    testWidgets(
        'organization cards retain public loading across filters; '
        'public request ends with ${fail ? "error" : "success"}',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final publicRequest = Completer<List<AgentItem>>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          communityEmployeesProvider
              .overrideWith((ref) => publicRequest.future),
          digitalEmployeeCatalogProvider
              .overrideWith(_ReadyOrganizationCatalog.new),
        ],
        child:
            const MaterialApp(home: Scaffold(body: CommunityEmployeeGallery())),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('组织员工'), findsOneWidget);
      expect(find.byType(AgentCardSkeleton), findsNWidgets(4));
      expect(find.byType(DigitalEmployeeGallerySkeleton), findsNothing);
      expect(find.text('暂无匹配的数字员工'), findsNothing);
      await tester.tap(find.text('组织', skipOffstage: false));
      await tester.pump();
      expect(find.text('组织员工'), findsOneWidget);
      expect(find.byType(AgentCardSkeleton), findsNothing);
      await tester.tap(find.text('我的', skipOffstage: false));
      await tester.pump();
      expect(find.byType(AgentCardSkeleton), findsNothing);
      await tester.tap(find.text('官方', skipOffstage: false));
      await tester.pump();
      expect(find.byType(AgentCardSkeleton), findsNWidgets(4));
      await tester.tap(find.text('全部', skipOffstage: false));
      await tester.pump();
      expect(find.text('组织员工'), findsOneWidget);
      expect(find.byType(AgentCardSkeleton), findsNWidgets(4));
      if (fail) {
        publicRequest.completeError(StateError('public directory unavailable'));
      } else {
        publicRequest.complete(const []);
      }
      await tester.pump();
      await tester.pump();
      expect(find.byType(AgentCardSkeleton), findsNothing);
      expect(find.text('组织员工'), findsOneWidget);
      expect(find.text('重试公共目录'), fail ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('community employee loading reuses the internal gallery skeleton',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
        overrides: [
          communityEmployeesProvider
              .overrideWith((ref) => Completer<List<AgentItem>>().future),
          digitalEmployeeCatalogProvider.overrideWith(_PendingCatalog.new),
        ],
        child: const MaterialApp(
            home: Scaffold(body: CommunityEmployeeGallery()))));
    await tester.pump();
    expect(find.byType(DigitalEmployeeGallerySkeleton), findsOneWidget);
    expect(find.text('公共数字员工加载中…'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
