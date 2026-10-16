import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/contacts/member_invite_api.dart';
import 'package:zhiban_client/pages/contacts/widgets/add_member_dialog.dart';

/// F28 codex 第 4 轮 P2：手机号 tab 的重复号拦截、20 条上限、结果逐行映射。
class _FakeMemberInviteService extends MemberInviteService {
  const _FakeMemberInviteService(this.results);

  final List<MemberAddByPhoneResult> results;

  static final List<List<({String phone, String name})>> sentBatches = [];

  @override
  Future<MemberInviteLink> fetchLink() async => MemberInviteLink(
        url: 'https://www.zbwork.cn/invite/member/#t=abc',
        expiresAt: DateTime.now().add(const Duration(days: 30)),
        tenantName: '北京元澄科技有限公司',
      );

  @override
  Future<List<MemberAddByPhoneResult>> addByPhone(
    List<({String phone, String name})> items,
  ) async {
    sentBatches.add(items);
    return results;
  }
}

Future<void> _pumpPhoneTab(
  WidgetTester tester,
  _FakeMemberInviteService fake,
) async {
  _FakeMemberInviteService.sentBatches.clear();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [memberInviteServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(
        home: Scaffold(body: AddMemberContent(showHeader: false)),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('手机号'));
  await tester.pumpAndSettle();
}

Future<void> _pumpQrTab(
  WidgetTester tester,
  _FakeMemberInviteService fake,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [memberInviteServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(
        home: Scaffold(body: AddMemberContent(showHeader: false)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fillRow(
  WidgetTester tester,
  int rowIndex,
  String phone,
  String name,
) async {
  final phoneFields = find.widgetWithText(TextField, '输入手机号');
  final nameFields = find.widgetWithText(TextField, '请输入姓名');
  await tester.enterText(phoneFields.at(rowIndex), phone);
  await tester.enterText(nameFields.at(rowIndex), name);
  await tester.pump();
}

void main() {
  testWidgets('手机号录入使用紧凑组合行并始终显示 +86', (tester) async {
    final fake = _FakeMemberInviteService(const []);
    await _pumpPhoneTab(tester, fake);

    expect(find.text('+86'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('member-invite-phone-row-0')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('member-invite-phone-row-1')),
        findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('member-invite-phone-row-0')))
          .height,
      44,
    );
  });

  testWidgets('二维码页提供保存图片和复制图片，链接页仍复制链接', (tester) async {
    final fake = _FakeMemberInviteService(const []);
    await _pumpQrTab(tester, fake);

    expect(find.text('保存二维码'), findsOneWidget);
    expect(find.text('复制二维码'), findsOneWidget);
    expect(find.text('复制链接'), findsNothing);

    await tester.tap(find.text('企业链接'));
    await tester.pumpAndSettle();

    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('保存二维码'), findsNothing);
    expect(find.text('复制二维码'), findsNothing);
    final messageBox = tester.widget<Container>(
      find.byKey(const ValueKey('member-invite-link-message')),
    );
    final messageColor = (messageBox.decoration! as BoxDecoration).color!;
    expect(
      messageColor.computeLuminance(),
      lessThan(const Color(0xFFF7F8FA).computeLuminance()),
      reason: '链接文本区域需与浅色外层卡片形成清晰层级',
    );
  });

  testWidgets('重复手机号在发送前拦截并逐行标红，不发请求', (tester) async {
    final fake = _FakeMemberInviteService(const []);
    await _pumpPhoneTab(tester, fake);

    await _fillRow(tester, 0, '13930153501', '张三');
    await _fillRow(tester, 1, '13930153501', '李四');
    await tester.tap(find.text('发送'));
    await tester.pump();

    expect(find.text('与上方手机号重复'), findsOneWidget);
    expect(_FakeMemberInviteService.sentBatches, isEmpty,
        reason: '存在重复号时不得发请求（响应按 phone 映射会错配）');
  });

  testWidgets('结果逐行映射：成功行移除，失败行保留并标注原因', (tester) async {
    final fake = _FakeMemberInviteService(const [
      MemberAddByPhoneResult(
          phone: '13930153501', ok: true, status: 'pending', smsSent: true),
      MemberAddByPhoneResult(
          phone: '13930153502', ok: false, error: 'already_member'),
    ]);
    await _pumpPhoneTab(tester, fake);

    await _fillRow(tester, 0, '13930153501', '张三');
    await _fillRow(tester, 1, '13930153502', '李四');
    await tester.tap(find.text('发送'));
    // 弹确认框期间发送按钮仍是 loading 态（有持续动画），用定次 pump 而非 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 请求只发一批、两条
    expect(_FakeMemberInviteService.sentBatches, hasLength(1));
    expect(_FakeMemberInviteService.sentBatches.single, hasLength(2));
    // 部分成功弹确认框
    expect(find.textContaining('已创建 1 个邀请'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 失败行保留 + 标注；成功行已移除（其手机号不再出现在输入框里）
    expect(find.text('已是企业成员'), findsOneWidget);
    final phones = tester
        .widgetList<TextField>(find.widgetWithText(TextField, '输入手机号'))
        .map((f) => f.controller?.text ?? '')
        .toList();
    expect(phones, isNot(contains('13930153501')));
    expect(phones, contains('13930153502'));
  });

  testWidgets('20 条上限：达到上限后继续添加禁用并提示', (tester) async {
    final fake = _FakeMemberInviteService(const []);
    await _pumpPhoneTab(tester, fake);

    // 初始 2 行，点 18 次到 20 行
    for (var i = 0; i < 18; i++) {
      await tester.ensureVisible(find.text('继续添加'));
      await tester.tap(find.text('继续添加'));
      await tester.pump();
    }
    expect(find.text('一次最多添加 20 人'), findsOneWidget);
    expect(find.text('继续添加'), findsNothing);
    // 再点不会加行
    await tester.ensureVisible(find.text('一次最多添加 20 人'));
    await tester.tap(find.text('一次最多添加 20 人'));
    await tester.pump();
    expect(
        tester.widgetList(find.widgetWithText(TextField, '输入手机号')).length, 20);
  });
}
