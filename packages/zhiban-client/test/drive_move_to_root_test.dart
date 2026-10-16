import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/services/drive_service.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_content_view.dart';

class _MoveToRootDriveService extends DriveService {
  static const spaceUuid = 'space-shared';
  static const level1Uuid = 'folder-level-1';
  static const level2Uuid = 'folder-level-2';
  static const level3Uuid = 'folder-level-3';

  final List<String> moveTargets = [];

  static final file = DriveFile(
    uuid: 'file-level-3',
    name: '三级目录文件.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 1024,
    source: 'drive_upload',
    spaceUuid: spaceUuid,
    driveFolderUuid: level3Uuid,
    createdAt: DateTime(2026, 7, 24),
    updatedAt: DateTime(2026, 7, 24),
  );

  @override
  Future<DriveBootstrap> bootstrap() async => const DriveBootstrap(
        personal: DriveSpace(
          uuid: 'space-personal',
          kind: 'personal',
          name: '',
          status: 'active',
        ),
        tenant: null,
        departments: [],
        shared: [
          DriveSpace(
            uuid: spaceUuid,
            kind: 'shared',
            name: '共享目录',
            status: 'active',
          ),
        ],
      );

  @override
  Future<List<DriveFolder>> folderTree(String requestedSpaceUuid) async {
    if (requestedSpaceUuid != spaceUuid) return const [];
    return const [
      DriveFolder(
        uuid: level1Uuid,
        name: '目录1',
        kind: 'regular',
        parentId: '',
        path: '/目录1/',
        isSystem: false,
      ),
      DriveFolder(
        uuid: level2Uuid,
        name: '目录1-1',
        kind: 'regular',
        parentId: level1Uuid,
        path: '/目录1/目录1-1/',
        isSystem: false,
      ),
      DriveFolder(
        uuid: level3Uuid,
        name: '目录1-1-1',
        kind: 'regular',
        parentId: level2Uuid,
        path: '/目录1/目录1-1/目录1-1-1/',
        isSystem: false,
      ),
    ];
  }

  @override
  Future<FolderChildren> listFolderChildren(
    String folderUuid, {
    int page = 1,
    int pageSize = 50,
  }) async {
    if (folderUuid != level3Uuid) {
      return const FolderChildren(folders: [], files: [], total: 0);
    }
    return FolderChildren(folders: const [], files: [file], total: 1);
  }

  @override
  Future<List<DriveFavoriteItem>> listFavorites({int limit = 100}) async =>
      const [];

  @override
  Future<DriveFile> moveFile({
    required String fileUuid,
    required String newFolderUuid,
  }) async {
    moveTargets.add(newFolderUuid);
    return file;
  }
}

class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(driveTreeProvider).value;
    final treeReady = tree?.foldersFor(_MoveToRootDriveService.spaceUuid).any(
            (folder) => folder.uuid == _MoveToRootDriveService.level3Uuid) ??
        false;
    if (!treeReady) {
      return const Scaffold(
        body: Center(child: CupertinoActivityIndicator())
      );
    }
    return const Scaffold(
      body: DriveContentView(
        selection: DriveSelection(
          kind: DriveSelectionKind.driveFolder,
          folderUuid: _MoveToRootDriveService.level3Uuid,
        ),
        space: _MoveToRootDriveService.spaceUuid,
      ),
    );
  }
}

void main() {
  testWidgets('三级目录文件选择移到根目录时提交空目标目录', (tester) async {
    final service = _MoveToRootDriveService();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [driveServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          builder: BotToastInit(),
          home: const _Harness()
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('三级目录文件.pdf'), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移到根目录'));
    await tester.pumpAndSettle();

    expect(service.moveTargets, ['']);
  });
}
