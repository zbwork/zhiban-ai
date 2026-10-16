import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/settings/share_invite_poster.dart';

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
    debugSaveSharePosterOverride = null;
  });

  testWidgets('好友邀请海报输出固定尺寸 PNG', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderShareInvitePoster(
        const ShareInvitePosterSpec(
          url: 'https://www.zbwork.cn/?ref=ZBAI-8K29',
          inviteCode: 'ZBAI-8K29',
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
          expect(frame.image.width, shareInvitePosterWidth);
          expect(frame.image.height, shareInvitePosterHeight);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    });
  });

  test('保存海报使用固定文件名并写入同一份 PNG', () async {
    final bytes = Uint8List.fromList(const [4, 5, 6]);
    Uint8List? saved;
    String? suggestedName;
    debugSaveSharePosterOverride = (value, name) async {
      saved = value;
      suggestedName = name;
      return '/tmp/$name';
    };

    final path = await saveShareInvitePoster(bytes);

    expect(saved, same(bytes));
    expect(suggestedName, '知办AI-好友邀请海报.png');
    expect(path, '/tmp/知办AI-好友邀请海报.png');
  });
}
