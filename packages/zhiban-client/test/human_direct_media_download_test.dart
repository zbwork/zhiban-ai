import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';

void main() {
  group('chat file download helpers', () {
    test('sanitizes unsafe desktop file names', () {
      expect(
        sanitizeChatDownloadFileName('  a/b\\c:*?"<>|.xlsx  '),
        'a_b_c_______.xlsx',
      );
      expect(sanitizeChatDownloadFileName('   '), '文件');
      expect(sanitizeChatDownloadFileName('..'), '文件');
    });

    test('unique target keeps first name when it does not exist', () {
      final dir = Directory.systemTemp.createTempSync('chat-download-target-');
      addTearDown(() => dir.deleteSync(recursive: true));

      final target = uniqueChatDownloadTarget(dir, '30天学习计划.xlsx');

      expect(target.path.endsWith('30天学习计划.xlsx'), isTrue);
    });

    test('unique target appends suffix without overwriting', () {
      final dir = Directory.systemTemp.createTempSync('chat-download-target-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}${Platform.pathSeparator}计划.xlsx')
          .writeAsStringSync('1');
      File('${dir.path}${Platform.pathSeparator}计划 (1).xlsx')
          .writeAsStringSync('2');

      final target = uniqueChatDownloadTarget(dir, '计划.xlsx');

      expect(target.path.endsWith('计划 (2).xlsx'), isTrue);
    });

    test('reveal command selects file on macOS', () {
      final cmd = revealChatDownloadCommand('/Users/me/Downloads/a.xlsx',
          platform: 'macos');

      expect(cmd?.executable, 'open');
      expect(cmd?.arguments, ['-R', '/Users/me/Downloads/a.xlsx']);
    });

    test('reveal command selects file on Windows', () {
      final cmd = revealChatDownloadCommand(r'C:\Users\me\Downloads\a.xlsx',
          platform: 'windows');

      expect(cmd?.executable, 'explorer.exe');
      expect(cmd?.arguments, [r'/select,C:\Users\me\Downloads\a.xlsx']);
    });

    test('reveal command opens parent directory on Linux', () {
      final cmd = revealChatDownloadCommand('/home/me/Downloads/a.xlsx',
          platform: 'linux');

      expect(cmd?.executable, 'xdg-open');
      expect(cmd?.arguments, ['/home/me/Downloads']);
    });
  });
}
