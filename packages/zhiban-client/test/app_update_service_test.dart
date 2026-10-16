import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/app_update_service.dart';

void main() {
  group('parseUpdateInfoPayload', () {
    test('parses available update from Bus response', () {
      final info = parseUpdateInfoPayload(
        {
          'update_available': true,
          'current_version': '0.7.55',
          'current_build_number': '755',
          'latest': {
            'version': '0.7.56',
            'build_number': '756',
            'title': '知办AI 0.7.56',
            'release_notes': '修复若干问题',
            'download_url': 'https://example.com/zhiban.dmg',
            'appcast_url': 'https://example.com/appcast.xml',
            'is_forced': true,
          },
        },
        currentVersion: '0.7.55',
        currentBuildNumber: '755',
      );

      expect(info.isUpdateAvailable, isTrue);
      expect(info.latestVersion, '0.7.56');
      expect(info.latestBuildNumber, '756');
      expect(info.title, '知办AI 0.7.56');
      expect(info.appcastUrl, 'https://example.com/appcast.xml');
      expect(info.isForced, isTrue);
    });

    test('returns no update when latest is absent', () {
      final info = parseUpdateInfoPayload(
        {
          'update_available': false,
          'current_version': '0.7.56',
          'current_build_number': '756',
          'latest': null,
        },
        currentVersion: '0.7.56',
        currentBuildNumber: '756',
      );

      expect(info.isUpdateAvailable, isFalse);
      expect(info.latestVersion, isEmpty);
      expect(info.currentVersion, '0.7.56');
    });
  });
}
