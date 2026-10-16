import 'dart:ui' show PointerDeviceKind;

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/layout/models/main_nav_item.dart';
import 'package:nexwork/layout/widgets/desktop_sidebar.dart';
import 'package:nexwork/layout/widgets/sidebar_billing_indicator.dart';
import 'package:nexwork/layout/widgets/sidebar_billing_section.dart';
import 'package:nexwork/layout/widgets/sidebar_community_section.dart';
import 'package:nexwork/layout/widgets/sidebar_update_indicator.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';
import 'package:nexwork/layout/widgets/sidebar_profile_popover.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoNetwork implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString('{"data":{}}', 200, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final items =
      mainNavItems.where((item) => item.path != RoutePaths.settings).toList();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previous = request.httpClientAdapter;
    request.httpClientAdapter = _NoNetwork();
    addTearDown(() => request.httpClientAdapter = previous);
  });

  testWidgets(
      'collapse preserves workspace, navigation, badges and billing state',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final router = GoRouter(initialLocation: RoutePaths.chat, routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Row(children: [
            DesktopSidebar(navItems: items, chatUnreadCount: 120),
            Expanded(child: child),
          ]),
        ),
        routes: [
          for (final item in items)
            GoRoute(
              path: item.path,
              builder: (_, __) => TextField(
                key: const ValueKey('workspace-input'),
                controller: controller,
              ),
            ),
        ],
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountInfoProvider.overrideWith((ref) async => AccountInfo.fromJson({
              'account': {'displayName': '这是一个很长的用户名称用于验证侧栏'},
            })),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
    expect(tester.getSize(sidebar).width, 180);
    final toggle = find.byType(SidebarToggleButton);
    final surface = find.byKey(const ValueKey('sidebar-toggle-surface'));
    void expectEdgeToggle() {
      final sidebarRect = tester.getRect(sidebar);
      final surfaceRect = tester.getRect(surface);
      final collapsed = tester.widget<SidebarToggleButton>(toggle).collapsed;
      expect(surfaceRect.center.dy,
          closeTo(sidebarRect.top + sidebarRect.height * 0.44, 0.01));
      expect(
          collapsed ? surfaceRect.left : surfaceRect.right, sidebarRect.right);
      expect(surfaceRect.size, const Size(12, 44));
      expect(tester.getSize(toggle), const Size(20, 52));
      final decoration =
          tester.widget<Container>(surface).decoration! as BoxDecoration;
      expect(decoration.border, isNull);
      expect(
          decoration.borderRadius,
          collapsed
              ? const BorderRadius.horizontal(right: Radius.circular(6))
              : const BorderRadius.horizontal(left: Radius.circular(6)));
    }

    expectEdgeToggle();
    Color toggleFill() =>
        (tester.widget<Container>(surface).decoration! as BoxDecoration).color!;
    final idleFill = toggleFill();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(850, 500));
    await mouse.moveTo(tester.getCenter(find.byType(SidebarUserAvatar)));
    await tester.pump();
    expect(toggleFill(), idleFill);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump();
    expect(toggleFill(), isNot(idleFill));
    await mouse.moveTo(const Offset(850, 500));
    await tester.pump();
    expect(toggleFill(), idleFill);
    await mouse.removePointer();
    final billingState = tester.state(find.byType(SidebarBillingSection));
    final workspaceElement = tester.element(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '未发送的内容');
    await tester.tap(find.byTooltip('收起菜单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final transitioningWidth = tester.getSize(sidebar).width;
    expect(transitioningWidth, greaterThan(64));
    expect(transitioningWidth, lessThan(180));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 64);
    expectEdgeToggle();
    expect(find.text('对话'), findsNothing);
    expect(find.byTooltip('对话'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);
    expect(find.byTooltip('我的企业'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.star_fill), findsOneWidget);
    expect(
        tester.state(find.byType(SidebarBillingSection)), same(billingState));
    expect(tester.element(find.byType(TextField)), same(workspaceElement));
    expect(controller.text, '未发送的内容');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(SidebarUserAvatar));
    await tester.pumpAndSettle();
    expect(find.byType(SidebarProfilePopover), findsOneWidget);
    Navigator.of(tester.element(find.byType(SidebarProfilePopover))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('我的企业'));
    await tester.pumpAndSettle();
    expect(find.byType(SidebarCompanyPopover), findsOneWidget);
    Navigator.of(tester.element(find.byType(SidebarCompanyPopover))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('数字员工'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path,
        RoutePaths.digitalEmployee);
    expect(tester.getSize(sidebar).width, 64);
    // The collapsed button is entirely outside the navigation panel.
    await tester.tapAt(Offset(
        tester.getRect(sidebar).right + 10, tester.getCenter(surface).dy));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 180);
    expect(find.text('数字员工'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(900, 820));
    await tester.pumpAndSettle();
    expectEdgeToggle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('toggle switches directional icons with keyboard Enter and Space',
      (tester) async {
    var collapsed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: StatefulBuilder(
          builder: (_, setState) => SidebarToggleButton(
                collapsed: collapsed,
                onTap: () => setState(() => collapsed = !collapsed),
              )),
    )));
    String iconAsset() =>
        (tester.widget<SvgPicture>(find.byType(SvgPicture)).bytesLoader
                as SvgAssetLoader)
            .assetName;
    expect(iconAsset(), endsWith('sidebar_collapse.svg'));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(collapsed, isTrue);
    expect(iconAsset(), endsWith('sidebar_expand.svg'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(collapsed, isFalse);
    expect(iconAsset(), endsWith('sidebar_collapse.svg'));
  });

  testWidgets('official community card opens the QR dialog', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: SidebarCommunitySection(),
          ),
        ),
      ),
    );

    expect(find.text('官方社群'), findsOneWidget);
    expect(find.text('免费福利 · 新品内测 · 官方答疑'), findsOneWidget);

    await tester.tap(find.text('官方社群'));
    await tester.pumpAndSettle();

    expect(find.byType(OfficialCommunityDialog), findsOneWidget);
    final dialog = tester.widget<UiContentDialog>(
      find.byType(UiContentDialog),
    );
    expect(dialog.size, UiDialogSize.compact);
    expect(dialog.maxHeight, 620);
    expect(find.text('加入知办AI官方社群'), findsOneWidget);
    expect(find.text('微信扫码，立即加入'), findsOneWidget);
    expect(find.text('和更多 AI 实践者一起交流'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.gift_fill), findsNothing);
    expect(find.textContaining('二维码失效'), findsNothing);

    final qrFinder = find.byWidgetPredicate(
      (widget) => widget is Image && widget.semanticLabel == '知办AI官方社群二维码',
    );
    final qr = tester.widget<Image>(qrFinder);
    expect(
        (qr.image as AssetImage).assetName, 'assets/images/community_qr.png');
  });

  testWidgets('compact billing and update retain actions and busy state',
      (tester) async {
    var billingTaps = 0;
    var updateTaps = 0;
    for (final stage in SidebarUpdateState.values) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 64,
        child: Column(children: [
          SidebarBillingIndicator(
            collapsed: true,
            planName: '免费版',
            credits: 93802940,
            totalCredits: 500,
            isLowCredit: false,
            onTap: () => billingTaps++,
          ),
          SidebarUpdateIndicator(
            collapsed: true,
            state: stage,
            onTap: stage.isBusy ? null : () => updateTaps++,
          ),
        ]),
      ))));
      await tester.tap(find.byIcon(CupertinoIcons.star_fill));
      if (stage.isBusy) {
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      } else {
        await tester.tap(find.byIcon(CupertinoIcons.arrow_2_circlepath));
      }
      expect(tester.takeException(), isNull);
    }
    expect(billingTaps, SidebarUpdateState.values.length);
    expect(
      updateTaps,
      SidebarUpdateState.values.where((stage) => !stage.isBusy).length,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
