import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';

void main() {
  group('WuKong desktop database factory', () {
    test('uses FFI only on Windows and Linux', () {
      expect(
        usesWukongFfiDatabaseFactory(isWindows: false, isLinux: false),
        isFalse,
      );
      expect(
        usesWukongFfiDatabaseFactory(isWindows: true, isLinux: false),
        isTrue,
      );
      expect(
        usesWukongFfiDatabaseFactory(isWindows: false, isLinux: true),
        isTrue,
      );
    });

    test('migrates legacy database and SQLite sidecar files once', () async {
      final root = await Directory.systemTemp.createTemp('wukong-db-test-');
      addTearDown(() => root.delete(recursive: true));
      final legacy = Directory('${root.path}/legacy')..createSync();
      final native = Directory('${root.path}/native');
      final legacyDb = File('${legacy.path}/wk_user-1.db');
      await legacyDb.writeAsString('database');
      await File('${legacyDb.path}-wal').writeAsString('wal');
      await File('${legacyDb.path}-shm').writeAsString('shm');

      expect(
        await migrateLegacyMacWukongDatabase(
          legacyDirectory: legacy,
          nativeDirectory: native,
          uid: 'user-1',
        ),
        isTrue,
      );
      expect(
          await File('${native.path}/wk_user-1.db').readAsString(), 'database');
      expect(
          await File('${native.path}/wk_user-1.db-wal').readAsString(), 'wal');
      expect(
          await File('${native.path}/wk_user-1.db-shm').readAsString(), 'shm');

      expect(
        await migrateLegacyMacWukongDatabase(
          legacyDirectory: legacy,
          nativeDirectory: native,
          uid: 'user-1',
        ),
        isFalse,
      );
    });
  });
}
