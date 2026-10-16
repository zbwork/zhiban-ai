// 侧栏两个弹框 (docs/contracts/agent-bus-client-contract.md §11.6) 的显隐规则:
// 头像弹框(左上): 身份区 + 设置/管理后台/退出登录 + 版本号;
//   - 管理后台仅在 scopes[].isAdmin 为 true 且 adminWebUrl 非空时出现;
//   - /auth/me 拉取失败 fail-closed: 管理后台隐藏, 设置/退出登录仍在。
// 我的企业弹框(底部): 企业列表, 当前租户 (act_tid) 打勾; 加载失败显示错误文案。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/layout/widgets/sidebar_profile_popover.dart';
import 'package:zhiban_core/models/account_info.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

AccountInfo _info() => const AccountInfo(
      employeeId: '',
      accountNo: 'zs',
      name: '张三',
      nickname: '张三',
      email: '',
      phone: '',
      avatar: '',
      departmentId: '',
      departmentName: '',
      departmentFullName: '',
      positionName: '',
      tenantId: 'acme',
      tenantName: 'Acme 科技',
      tenantType: '',
      welcomeMsg: '',
      walletBalance: 0,
      walletBalanceYuan: '',
    );

MeResult _me({required bool isAdmin, required int tenantCount}) {
  return MeResult(
    account: const {},
    scopes: [
      for (var i = 1; i <= tenantCount; i++)
        ScopeOption(
          kind: 'tenant',
          tenantId: i,
          tenantName: i == 1 ? 'Acme 科技' : '元澄科技',
          memberDisplayName: '张三',
          isAdmin: isAdmin,
        ),
    ],
  );
}

/// 混合 scope: 账号在某一个租户是管理员、在另一个租户只是普通成员——2026-08-24
/// 修复的真实场景("A 租户管理员切到 B 租户不该看到管理后台")。
MeResult _mixedMe({required int adminTenantId, required int memberTenantId}) {
  return MeResult(
    account: const {},
    scopes: [
      ScopeOption(
        kind: 'tenant',
        tenantId: adminTenantId,
        tenantName: '管理员租户',
        memberDisplayName: '张三',
        isAdmin: true,
      ),
      ScopeOption(
        kind: 'tenant',
        tenantId: memberTenantId,
        tenantName: '普通成员租户',
        memberDisplayName: '张三',
        isAdmin: false,
      ),
    ],
  );
}

Widget _profileHost({
  required Future<MeResult> Function() loadMe,
  MeResult? initialMe,
  int currentTenantId = 1,
  bool? localCodingToolsAvailable,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => SingleChildScrollView(
            child: SidebarProfilePopover(
              info: _info(),
              hostContext: ctx,
              initialMe: initialMe,
              loadMe: loadMe,
              loadCurrentTenantId: () async => currentTenantId,
              localCodingToolsAvailable: localCodingToolsAvailable,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _companyHost({
  required Future<MeResult> Function() loadMe,
  MeResult? initialMe,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => SingleChildScrollView(
          child: SidebarCompanyPopover(
            hostContext: ctx,
            initialMe: initialMe,
            loadMe: loadMe,
            loadCurrentTenantId: () async => 1,
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('账号信息按 access token 当前组织匹配名称', () {
    final info = AccountInfo.fromJson(
      <String, dynamic>{
        'account': <String, dynamic>{'displayName': '张三'},
        'scopes': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'tenant',
            'tenantId': 1,
            'tenantName': '旧组织'
          },
          <String, dynamic>{
            'kind': 'tenant',
            'tenantId': 2,
            'tenantName': '当前组织'
          },
        ],
      },
      activeTenantId: '2',
    );
    expect(info.tenantName, '当前组织');
  });

  test('账号信息与企业列表复用同一份 authMeProvider 数据', () async {
    SharedPreferences.setMockInitialValues({});
    var loadCount = 0;
    final container = ProviderContainer(
      overrides: [
        authMeProvider.overrideWith((ref) async {
          loadCount += 1;
          return _me(isAdmin: false, tenantCount: 2);
        }),
      ],
    );
    addTearDown(container.dispose);

    final accountInfo = await container.read(accountInfoProvider.future);
    final me = await container.read(authMeProvider.future);

    expect(accountInfo?.tenantName, 'Acme 科技');
    expect(me.tenantScopes, hasLength(2));
    expect(loadCount, 1);

    container.invalidate(authMeProvider);
    await container.read(accountInfoProvider.future);
    expect(loadCount, 2);
  });

  group('头像弹框', () {
    testWidgets('admin 账号: 身份区/帮助与客服/设置/退出登录/管理后台可见, 不含企业列表', (tester) async {
      await tester.pumpWidget(
        _profileHost(loadMe: () async => _me(isAdmin: true, tenantCount: 2)),
      );
      await tester.pumpAndSettle();

      expect(find.text('张三'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.pencil), findsOneWidget); // 名字旁编辑笔
      expect(find.text('Acme 科技'), findsOneWidget); // 身份区副行 (当前企业)
      expect(find.text('帮助与客服'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      // dev 环境 adminWebUrl 默认非空 → isAdmin 账号可见管理后台。
      expect(find.text('管理后台'), findsOneWidget);
      // 只有管理后台是外链；帮助与客服进入应用内知办客服会话。
      expect(find.byIcon(CupertinoIcons.arrow_up_right_square), findsOneWidget);
      // 企业切换已移到「我的企业」弹框, 头像弹框不再展示列表。
      expect(find.text('我的企业'), findsNothing);
      expect(find.text('元澄科技'), findsNothing);
    });

    testWidgets('普通成员: 无管理后台', (tester) async {
      await tester.pumpWidget(
        _profileHost(loadMe: () async => _me(isAdmin: false, tenantCount: 1)),
      );
      await tester.pumpAndSettle();

      expect(find.text('管理后台'), findsNothing);
      expect(find.text('帮助与客服'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
    });

    testWidgets('F31 · 本地开发工具入口: 可用时显示在「帮助与客服」与「设置」之间, 不可用时不显示',
        (tester) async {
      await tester.pumpWidget(
        _profileHost(
          loadMe: () async => _me(isAdmin: false, tenantCount: 1),
          localCodingToolsAvailable: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地开发工具'), findsOneWidget);
      final help = tester.getTopLeft(find.text('帮助与客服')).dy;
      final tools = tester.getTopLeft(find.text('本地开发工具')).dy;
      final settings = tester.getTopLeft(find.text('设置')).dy;
      expect(help < tools && tools < settings, isTrue);
      // 应用内跳转, 不是外链: 不带跳出图标。
      expect(find.byIcon(CupertinoIcons.arrow_up_right_square), findsNothing);

      await tester.pumpWidget(
        _profileHost(
          loadMe: () async => _me(isAdmin: false, tenantCount: 1),
          localCodingToolsAvailable: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地开发工具'), findsNothing);
      expect(find.text('设置'), findsOneWidget);
    });

    testWidgets('跨租户: 在 A 租户是管理员、当前在 B 租户只是普通成员时不显示管理后台', (tester) async {
      await tester.pumpWidget(
        _profileHost(
          loadMe: () async => _mixedMe(adminTenantId: 588, memberTenantId: 1),
          currentTenantId: 1, // 当前在普通成员租户
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('管理后台'), findsNothing);
    });

    testWidgets('跨租户: 当前切到自己是管理员的那个租户时显示管理后台', (tester) async {
      await tester.pumpWidget(
        _profileHost(
          loadMe: () async => _mixedMe(adminTenantId: 588, memberTenantId: 1),
          currentTenantId: 588, // 当前在管理员租户
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('管理后台'), findsOneWidget);
    });

    testWidgets('/auth/me 失败: fail-closed 隐藏管理后台, 基础入口仍可用', (tester) async {
      await tester.pumpWidget(
        _profileHost(loadMe: () async => throw Exception('network down')),
      );
      await tester.pumpAndSettle();

      expect(find.text('管理后台'), findsNothing);
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('Acme 科技'), findsOneWidget); // 身份区回退 AccountInfo 缓存
      expect(find.text('帮助与客服'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
    });

    testWidgets('点击身份区: 弹个人名片卡片, 且弹框本体保持打开', (tester) async {
      await tester.pumpWidget(
        _profileHost(loadMe: () async => _me(isAdmin: false, tenantCount: 1)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();

      expect(find.text('邮箱'), findsOneWidget);
      expect(find.text('部门'), findsOneWidget);
      expect(find.text('企业'), findsOneWidget);
      expect(find.text('我'), findsOneWidget); // isSelf 标签
      expect(find.text('发消息'), findsOneWidget); // 按钮存在 (对自己禁用)
      // 对齐企业微信: 名片叠加展示, 头像弹框不关闭。
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
    });
  });

  group('我的企业弹框', () {
    testWidgets('已有会话缓存: 首帧直接展示企业列表且不重复加载', (tester) async {
      var loadCount = 0;
      await tester.pumpWidget(
        _companyHost(
          initialMe: _me(isAdmin: false, tenantCount: 2),
          loadMe: () async {
            loadCount += 1;
            throw StateError('不应重复请求 /auth/me');
          },
        ),
      );

      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.text('Acme 科技'), findsOneWidget);
      expect(find.text('元澄科技'), findsOneWidget);
      expect(loadCount, 0);
    });

    testWidgets('双租户: 无标题头, 列出两家企业, 当前租户蓝色打勾', (tester) async {
      await tester.pumpWidget(
        _companyHost(loadMe: () async => _me(isAdmin: false, tenantCount: 2)),
      );
      await tester.pumpAndSettle();

      // 对齐企业微信: 弹框内没有「我的企业」标题头, 直接是企业列表。
      expect(find.text('我的企业'), findsNothing);
      expect(find.text('Acme 科技'), findsOneWidget);
      expect(find.text('元澄科技'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.building_2_fill), findsNWidgets(2));
      expect(find.byIcon(CupertinoIcons.checkmark_alt), findsOneWidget);
      final currentText =
          tester.widget<Text>(find.text('Acme 科技')).style?.color;
      expect(currentText, const Color(0xFF2563EB)); // 当前企业蓝色高亮
      // 紧凑密度守护: 宽 240 / 行高 36 + 卡片上下 4, 双租户整卡不得超过 82px。
      final size = tester.getSize(find.byType(SidebarCompanyPopover));
      expect(size.height, lessThanOrEqualTo(82));
      expect(size.width, 240);
    });

    testWidgets('单租户: 仅当前企业一行且打勾 (入口恒显)', (tester) async {
      await tester.pumpWidget(
        _companyHost(loadMe: () async => _me(isAdmin: false, tenantCount: 1)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Acme 科技'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.checkmark_alt), findsOneWidget);
    });

    testWidgets('加载失败: 显示错误文案, 不渲染企业行', (tester) async {
      await tester.pumpWidget(
        _companyHost(loadMe: () async => throw Exception('network down')),
      );
      await tester.pumpAndSettle();

      expect(find.text('企业列表加载失败，请稍后重试'), findsOneWidget);
      expect(find.text('Acme 科技'), findsNothing);
    });
  });
}
