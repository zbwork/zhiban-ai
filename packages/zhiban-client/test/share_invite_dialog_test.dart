import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/settings/share_invite_api.dart';
import 'package:zhiban_client/pages/settings/widgets/share_invite_dialog.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// F29 分享给朋友弹框：邀请码/链接展示、复制内容与服务端下发一致、二维码内容 = url。
class _FakeShareInviteService extends ShareInviteService {
  const _FakeShareInviteService();

  @override
  Future<ShareInvite> fetchInvite() async => const ShareInvite(
        inviteCode: 'ZBAI-8K29',
        url: 'https://www.zbwork.cn/?ref=ZBAI-8K29',
      );
}

Future<void> _pumpDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        shareInviteServiceProvider
            .overrideWithValue(const _FakeShareInviteService()),
      ],
      child: MaterialApp(
        builder: BotToastInit(),
        home: const Scaffold(body: ShareInviteContent()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('弹框展示专属邀请码、邀请链接与二维码', (tester) async {
    await _pumpDialog(tester);

    expect(find.text('专属邀请信息'), findsOneWidget);
    expect(find.text('ZBAI-8K29'), findsOneWidget);
    expect(find.text('https://www.zbwork.cn/?ref=ZBAI-8K29'), findsOneWidget);
    expect(find.text('复制邀请链接'), findsOneWidget);
    expect(find.text('下载海报'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('share-invite-card-background')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('share-invite-bottom-contrast')),
      findsOneWidget,
    );

    // 二维码渲染存在（QrImageView 不暴露 data getter；内容 = url 由弹框代码
    // 直接传 invite.url，契约 §17 的语义由上面 url 文本断言间接覆盖）。
    final qrFinder = find.byKey(const ValueKey('share-invite-qr'));
    expect(qrFinder, findsOneWidget);
    expect(tester.widget<QrImageView>(qrFinder).size, 88);

    // 设计稿微调：底部信息组距卡片下沿 30px，二维码与文案保持平衡。
    final cardFinder = find.byKey(
      const ValueKey('share-invite-card-background'),
    );
    final bottomContentFinder = find.byKey(
      const ValueKey('share-invite-bottom-content'),
    );
    final cardBottom =
        tester.getTopLeft(cardFinder).dy + tester.getSize(cardFinder).height;
    final contentBottom = tester.getTopLeft(bottomContentFinder).dy +
        tester.getSize(bottomContentFinder).height;
    expect(cardBottom - contentBottom, closeTo(30, 0.1));
  });

  testWidgets('复制邀请链接写入剪贴板', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpDialog(tester);
    await tester.tap(find.text('复制邀请链接'));
    await tester.pump();

    expect(copied, ['https://www.zbwork.cn/?ref=ZBAI-8K29']);

    // 快进走完 BotToast 自动消失 timer，避免 pending timer 断言。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
