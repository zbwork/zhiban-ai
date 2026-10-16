import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/contacts/member_invite_poster.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader = FontLoader('packages/zhiban_ui/HarmonyOS Sans SC')
      ..addFont(rootBundle.load(
        'packages/zhiban_ui/assets/fonts/harmonyos-sans/HarmonyOS_Sans_SC.ttf'),
      );
    await loader.load();
  });

  tearDown(() {
    debugCopyInvitePosterOverride = null;
    debugSaveInvitePosterOverride = null;
  });

  testWidgets('企业邀请海报输出固定尺寸 PNG', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderMemberInvitePoster(
        MemberInvitePosterSpec(
          url: 'https://www.zbwork.cn/invite/member/#t=test-token',
          tenantName: '北京元澄科技有限公司',
          inviterName: '李强',
          expiresAt: DateTime(2026, 8, 28),
        ),
      );
      expect(
        bytes.take(8),
        orderedEquals(const [137, 80, 78, 71, 13, 10, 26, 10]),
      );
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, memberInvitePosterWidth);
          expect(frame.image.height, memberInvitePosterHeight);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    });
  });

  test('复制二维码把 PNG 图片字节写入剪贴板', () async {
    final bytes = Uint8List.fromList(const [1, 2, 3]);
    Uint8List? copied;
    debugCopyInvitePosterOverride = (value) async => copied = value;

    await copyMemberInvitePoster(bytes);

    expect(copied, same(bytes));
  });

  test('保存二维码使用安全文件名并写入同一份 PNG', () async {
    final bytes = Uint8List.fromList(const [4, 5, 6]);
    Uint8List? saved;
    String? suggestedName;
    debugSaveInvitePosterOverride = (value, name) async {
      saved = value;
      suggestedName = name;
      return '/tmp/$name';
    };

    final path = await saveMemberInvitePoster(
      bytes,
      tenantName: '元澄/科技:测试'
    );

    expect(saved, same(bytes));
    expect(suggestedName, '元澄_科技_测试-企业邀请二维码.png');
    expect(path, '/tmp/元澄_科技_测试-企业邀请二维码.png');
  });
}
