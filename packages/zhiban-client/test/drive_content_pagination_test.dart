import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/services/drive_service.dart';

/// 覆盖本轮 item 四：DriveContentNotifier 分页 loadMore——按 uuid 去重合并、
/// hasMore 推断（后端 total 仅文件数，folders 同 page 分页无 total）。
DriveFile _file(String uuid) => DriveFile.fromJson({'uuid': uuid});
DriveFolder _folder(String uuid) =>
    DriveFolder.fromJson({'uuid': uuid, 'name': uuid});

class _FakeDriveService extends DriveService {
  _FakeDriveService(this.pages);
  final Map<int, FolderChildren> pages;
  final List<int> requestedPages = [];

  @override
  Future<FolderChildren> listFolderChildren(
    String folderUuid, {
    int page = 1,
    int pageSize = 50,
  }) async {
    requestedPages.add(page);
    return pages[page] ??
        const FolderChildren(folders: [], files: [], total: 0);
  }
}

void main() {
  test('loadMore 合并去重 + 翻页推进 + hasMore', () async {
    final page1 = FolderChildren(
      folders: [_folder('d1')],
      files: [for (var i = 0; i < 50; i++) _file('f$i')],
      total: 120,
    );
    // page2 故意重复 d1 与 f49，验证 uuid 去重。
    final page2 = FolderChildren(
      folders: [_folder('d1')],
      files: [for (var i = 49; i < 99; i++) _file('f$i')],
      total: 120,
    );
    final fake = _FakeDriveService({1: page1, 2: page2});
    final container = ProviderContainer(
      overrides: [driveServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    // 持有订阅，避免 autoDispose 在两次 read 之间回收 notifier 丢掉分页状态。
    container.listen(driveContentProvider('folder1'), (_, __) {},
        fireImmediately: true);

    final first = await container.read(driveContentProvider('folder1').future);
    expect(first.page, 1);
    expect(first.children!.files.length, 50);
    expect(first.hasMore, true); // 1*50 < 120

    await container.read(driveContentProvider('folder1').notifier).loadMore();
    final after = container.read(driveContentProvider('folder1')).asData!.value;
    expect(after.page, 2);
    expect(after.children!.files.length, 99); // f0..f98 去重后 99 条
    expect(after.children!.folders.length, 1); // d1 去重为 1
    expect(after.hasMore, true); // 2*50 < 120
    expect(fake.requestedPages, [1, 2]);
  });

  test('文件拉完且 folder 页未满 → hasMore=false', () async {
    final page1 = FolderChildren(
      folders: [_folder('d1')],
      files: [for (var i = 0; i < 30; i++) _file('f$i')],
      total: 30,
    );
    final fake = _FakeDriveService({1: page1});
    final container = ProviderContainer(
      overrides: [driveServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.listen(driveContentProvider('folder1'), (_, __) {},
        fireImmediately: true);

    final first = await container.read(driveContentProvider('folder1').future);
    expect(first.hasMore, false); // 1*50 >= 30 且 folders(1) < 50
  });
}
