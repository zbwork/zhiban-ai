import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

class _StaticCatalog extends DigitalEmployeeCatalogNotifier {
  _StaticCatalog(this.catalog);

  final DigitalEmployeeCatalog catalog;

  @override
  Future<DigitalEmployeeCatalog> build() async => catalog;
}

void main() {
  group('digital employee desktop gallery layout', () {

    test('empty capability rows are hidden', () {
      final labels = debugVisibleAgentCapabilityRowLabels(
        skillNames: const [],
        appNames: const ['日程'],
        kbNames: const [],
      );

      expect(labels, ['应用']);
    });

    test(
        'agent card menu is hover-only on desktop and always visible on mobile',
        () {
      expect(
        debugShouldShowAgentCardMenu(
          alwaysVisible: false,
          cardActive: false
        ),
        isFalse,
      );
      expect(
        debugShouldShowAgentCardMenu(
          alwaysVisible: false,
          cardActive: true
        ),
        isTrue,
      );
      expect(
        debugShouldShowAgentCardMenu(
          alwaysVisible: true,
          cardActive: false
        ),
        isTrue,
      );
    });
  });

  group('digital employee mobile gallery layout', () {
    for (final width in [320.0]) {
      for (final scale in [3.0]) {
        testWidgets('source labels fit width $width at text scale $scale',
            (tester) async {
          tester.view.physicalSize = Size(width, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          for (final label in ['官方创建', '组织创建', '我创建的']) {
            await tester.pumpWidget(MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale)
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width - 30,
                    child: AgentCard(
                      agent: _agent(id: 'scaled', description: '暂无简介'),
                      sourceLabel: label,
                      canEdit: true,
                      mobile: true,
                      onTap: () {},
                      onEdit: () {},
                      onDelete: () {},
                    ),
                  ),
                ),
              ),
            ));
            await tester.pump();
            expect(tester.takeException(), isNull);
            final textRect = tester.getRect(find.text(label));
            final tagRect = tester.getRect(find.byType(AgentSourceTag));
            expect(textRect.left, greaterThanOrEqualTo(tagRect.left));
            expect(textRect.right, lessThanOrEqualTo(tagRect.right));
            expect(textRect.bottom, lessThanOrEqualTo(tagRect.bottom));
          }
        });
      }
    }

    testWidgets('mobile gallery shows category tabs and filters real sources',
        (tester) async {
      tester.view.physicalSize = const Size(393, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final catalog = DigitalEmployeeCatalog(
        personal: [
          DigitalEmployeeCatalogItem.personal(
            _agent(id: 'personal', description: '个人员工'),
          ),
        ],
        enterprise: [
          DigitalEmployeeCatalogItem(
            agent: _agent(id: 'enterprise', description: '组织员工'),
            source: DigitalEmployeeCatalogSource.enterprise,
          ),
        ],
        platform: [
          DigitalEmployeeCatalogItem(
            agent: _agent(id: 'platform', description: '平台员工'),
            source: DigitalEmployeeCatalogSource.platform,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalEmployeeCatalogProvider.overrideWith(
              () => _StaticCatalog(catalog),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: OpenClawDigitalEmployeeGallery(
                mobile: true,
                requestCreateAgentDraft: (_) async => null,
                requestEditAgentDraft: (_, __) async => null,
                showToast: (_) {},
                onOpenConversation: (_, __) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(UiSlantedTabs<DigitalEmployeeCatalogFilter>),
          findsOneWidget);
      expect(
        tester
            .widget<ColoredBox>(
              find.byKey(
                const ValueKey('digital-employee-mobile-list-background'),
              ),
            )
            .color,
        Colors.white,
      );
      expect(find.byType(AgentCard), findsNWidgets(3));
      expect(
        tester.widgetList<AgentCard>(find.byType(AgentCard)).every(
              (card) => card.mobile
            ),
        isTrue,
      );
      final firstCard = find.byType(AgentCard).first;
      expect(tester.getSize(firstCard).width, 363);
      expect(tester.getTopLeft(firstCard).dx, 15);

      final mobileTabs =
          find.byType(UiSlantedTabs<DigitalEmployeeCatalogFilter>);
      await tester.tap(
        find.descendant(of: mobileTabs, matching: find.text('我的')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-agent-card-personal')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('mobile-agent-card-enterprise')),
          findsNothing);

      await tester.tap(
        find.descendant(of: mobileTabs, matching: find.text('组织')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-agent-card-personal')),
          findsNothing);
      expect(find.byKey(const ValueKey('mobile-agent-card-enterprise')),
          findsOneWidget);

      await tester.tap(
        find.descendant(of: mobileTabs, matching: find.text('官方')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-agent-card-personal')),
          findsNothing);
      expect(find.byKey(const ValueKey('mobile-agent-card-enterprise')),
          findsNothing);
      expect(find.byKey(const ValueKey('mobile-agent-card-platform')),
          findsOneWidget);
    });
  });
}

AgentItem _agent({
  required String id,
  required String description,
  List<AgentSkillItem> skills = const [],
}) {
  return AgentItem(
    agentId: id,
    name: '招聘助手',
    description: description,
    avatarUrl: '',
    skills: skills,
    status: 'published',
    isDefault: false,
    syncStatus: 'synced',
    lastSyncedAt: null,
  );
}
