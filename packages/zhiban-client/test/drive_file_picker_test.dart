// 「选择云盘文件」弹框数据接入 widget 测试。
//
// 回归点(此前 bug:picker 用 legacy 'personal'/'org' coarse key 调
// rootFoldersOf('personal'),而 treesBySpaceUuid 按真实 space_uuid 存,导致
// 左侧空间下没有目录、右侧永远占位):
//   1. bootstrap 返回 personal + shared spaces 后,左侧展示「我的空间 / 共享空间」,
//      并列出真实 shared space 名(123 / 嘻嘻)。
//   2. 默认选中「我的空间」根 → 右侧展示 personal root files。
//   3. 点击 shared space 根 → 右侧展示该 shared space root files。
//   4. 点击目录 → 右侧展示目录 children files。
//   5. 不出现知识库 / 最近使用 / 回收站入口。
//   6. 多选文件后「确定 (N)」计数正确。
//
// 用 fake DriveService 注入(flutter test 屏蔽真实网络);全程真实 space_uuid。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/services/drive_service.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDriveService extends DriveService {
  const _FakeDriveService();

  static const personalUuid = 'uuid-personal';
  static const shared123Uuid = 'uuid-shared-123';
  static const sharedXxUuid = 'uuid-shared-xx';
  static const personalFolderUuid = 'uuid-folder-myproj';

  @override
  Future<DriveBootstrap> bootstrap() async => const DriveBootstrap(
        personal: DriveSpace(
            uuid: personalUuid, kind: 'personal', name: '', status: 'active'),
        tenant: null,
        departments: [],
        shared: [
          DriveSpace(
              uuid: shared123Uuid,
              kind: 'shared',
              name: '123',
              status: 'active'),
          DriveSpace(
              uuid: sharedXxUuid,
              kind: 'shared',
              name: '嘻嘻',
              status: 'active'),
        ],
      );

  @override
  Future<List<DriveFolder>> folderTree(String spaceUuid) async {
    if (spaceUuid == personalUuid) {
      return const [
        DriveFolder(
          uuid: personalFolderUuid,
          name: '我的项目',
          kind: 'regular',
          parentId: '',
          path: '/我的项目/',
          isSystem: false,
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<DriveFile>> listRootFiles(String spaceUuid) async {
    if (spaceUuid == personalUuid) {
      return [_file('personal-root.txt', personalUuid)];
    }
    if (spaceUuid == shared123Uuid) {
      return [_file('shared-123-root.txt', shared123Uuid)];
    }
    return const <DriveFile>[];
  }

  @override
  Future<FolderChildren> listFolderChildren(String folderUuid,
      {int page = 1, int pageSize = 50}) async {
    if (folderUuid == personalFolderUuid) {
      return FolderChildren(
        folders: const [],
        files: [
          _file('folder-child-a.txt', personalUuid, folderUuid),
          _file('folder-child-b.txt', personalUuid, folderUuid),
        ],
        total: 2,
      );
    }
    return const FolderChildren(folders: [], files: [], total: 0);
  }

  static DriveFile _file(String name, String spaceUuid, [String folder = '']) =>
      DriveFile(
        uuid: 'file-$name',
        name: name,
        mimeType: 'text/plain',
        sizeBytes: 1024,
        source: 'upload',
        spaceUuid: spaceUuid,
        driveFolderUuid: folder,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
}

class _Harness extends StatelessWidget {
  const _Harness();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => Center(
            child: ElevatedButton(
              onPressed: () => showDriveFilePicker(context, ref),
              child: const Text('open-picker'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openPicker(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 桌面双栏弹框宽 960,放大测试画布避免溢出。
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        driveServiceProvider.overrideWithValue(const _FakeDriveService()),
      ],
      child: const _Harness(),
    ),
  );
  await tester.tap(find.text('open-picker'));
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('左侧展示 我的空间 / 共享空间 + 真实 shared space 名,默认展示 personal root files',
      (tester) async {
    await _openPicker(tester);

    // 左侧两个顶层入口。
    expect(find.text('我的空间'), findsWidgets);
    expect(find.text('共享空间'), findsWidgets);
    // 共享分组默认展开,列出真实 shared space。
    expect(find.text('123'), findsOneWidget);
    expect(find.text('嘻嘻'), findsOneWidget);
    // 个人空间默认展开,显示其目录。
    expect(find.text('我的项目'), findsOneWidget);

    // 默认选中「我的空间」根 → 右侧展示 personal root files。
    expect(find.text('personal-root.txt'), findsOneWidget);

    // 不展示知识库 / 最近使用 / 回收站。
    expect(find.text('知识库'), findsNothing);
    expect(find.text('最近使用'), findsNothing);
    expect(find.text('回收站'), findsNothing);
  });

  testWidgets('点击 shared space 根 → 展示该 shared space root files', (tester) async {
    await _openPicker(tester);

    await tester.tap(find.text('123'));
    await tester.pumpAndSettle();

    expect(find.text('shared-123-root.txt'), findsOneWidget);
    // 切到共享空间后不应再显示个人根文件。
    expect(find.text('personal-root.txt'), findsNothing);
  });

  testWidgets('点击目录 → 展示目录 children files', (tester) async {
    await _openPicker(tester);

    await tester.tap(find.text('我的项目'));
    await tester.pumpAndSettle();

    expect(find.text('folder-child-a.txt'), findsOneWidget);
    expect(find.text('folder-child-b.txt'), findsOneWidget);
  });

  testWidgets('多选文件后「确定 (N)」计数正确', (tester) async {
    await _openPicker(tester);

    // 进目录拿到两个文件。
    await tester.tap(find.text('我的项目'));
    await tester.pumpAndSettle();

    // 初始 0。
    expect(find.text('确定 (0)'), findsOneWidget);

    await tester.tap(find.text('folder-child-a.txt'));
    await tester.pump();
    expect(find.text('确定 (1)'), findsOneWidget);

    await tester.tap(find.text('folder-child-b.txt'));
    await tester.pump();
    expect(find.text('确定 (2)'), findsOneWidget);

    // 再点一次取消选择 → 回到 1。
    await tester.tap(find.text('folder-child-a.txt'));
    await tester.pump();
    expect(find.text('确定 (1)'), findsOneWidget);
  });
}
