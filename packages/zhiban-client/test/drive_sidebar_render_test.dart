// 侧栏渲染 widget 测试 —— 用「真实形态」数据(个人空间 + 部门 运维部 + de_root 数字员工)
// 喂给 DrivePage,验证:
//   1. 不再无限 loading(provider 解析后 spinner 消失)
//   2. F06 IA cutover:顶层两桶「我的空间 / 共享空间」,二级保留「云盘 / 知识库」
//   3. 仍有的组织侧 space(过渡期遗留,如 运维部)作为共享云盘下的协作文件夹节点
//   4. 个人空间的 de_root「数字员工」可见
// 用 fake DriveService 注入,避免 flutter test 屏蔽真实网络的限制。
import 'package:bot_toast/bot_toast.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:zhiban_client/pages/drive/drive_page.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/services/drive_service.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_icon.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_desktop_layout.dart';
import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:zhiban_client/pages/knowledge/providers/knowledge_providers.dart';
import 'package:zhiban_client/pages/knowledge/services/knowledge_service.dart';
import 'package:zhiban_ui/widgets/ui_dropdown_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 形态取自真后端 :8080 bootstrap 实测响应。
class _FakeDriveService extends DriveService {
  const _FakeDriveService();

  static const personalUuid = 'c527fa59-personal';
  static const deptUuid = '92bdce0f-dept';
  static const sharedUuid = '34b8-shared';

  @override
  Future<DriveBootstrap> bootstrap() async => const DriveBootstrap(
        personal: DriveSpace(
            uuid: personalUuid, kind: 'personal', name: '', status: 'active'),
        tenant: null,
        departments: [
          DriveSpace(
              uuid: deptUuid,
              kind: 'department',
              name: '运维部',
              status: 'active'),
        ],
        shared: [
          DriveSpace(
            uuid: sharedUuid,
            kind: 'shared',
            name: '测试',
            status: 'active',
          ),
        ],
      );

  @override
  Future<List<DriveFolder>> folderTree(String spaceUuid) async {
    if (spaceUuid == personalUuid) {
      return const [
        DriveFolder(
          uuid: 'de-root',
          name: '数字员工',
          kind: 'de_root',
          parentId: '',
          path: '/数字员工/',
          isSystem: true,
        ),
        DriveFolder(
          uuid: 'folder-hi',
          name: 'hi',
          kind: 'regular',
          parentId: '',
          path: '/hi/',
          isSystem: false,
        ),
      ];
    }
    return const [];
  }

  @override
  Future<FolderChildren> listFolderChildren(String folderUuid,
          {int page = 1, int pageSize = 50}) async =>
      const FolderChildren(folders: [], files: [], total: 0);

  @override
  Future<List<DriveFile>> listRootFiles(String spaceUuid) async {
    if (spaceUuid == sharedUuid) {
      return [
        DriveFile(
          uuid: 'shared-file-pdf',
          name: '3月cursor.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 301900,
          source: 'drive_upload',
          spaceUuid: sharedUuid,
          driveFolderUuid: '',
          createdAt: DateTime(2026, 6, 11),
          updatedAt: DateTime(2026, 6, 11),
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<DriveFavoriteItem>> listFavorites({int limit = 100}) async =>
      const [];

  @override
  Future<List<RecycleItem>> listRecycle({int limit = 100}) async {
    return [
      RecycleItem(
        uuid: 'recycle-png',
        targetKind: 'file',
        spaceUuid: personalUuid,
        name: '0q5ptoTD8.png',
        locationPath: '我的空间 / 云盘 / hu12',
        deletedByDisplayName: '李3',
        deletedAtLogical: DateTime(2026, 6, 11, 11, 47),
        expiresAt: DateTime(2026, 7, 11, 11, 47),
        bytesToReclaim: 242483,
      ),
    ];
  }

  @override
  Future<PreviewUrl> recyclePreviewUrl(String recycleUuid) async {
    throw UnsupportedError('fake recycle preview');
  }
}

class _FavoriteMutationDriveService extends _FakeDriveService {
  final List<({String targetKind, String targetUuid, String kbUuid})>
      addFavoriteCalls = [];

  @override
  Future<void> addFavorite({
    required String targetKind,
    required String targetUuid,
    String kbUuid = '',
  }) async {
    addFavoriteCalls.add((
      targetKind: targetKind,
      targetUuid: targetUuid,
      kbUuid: kbUuid,
    ));
  }
}

class _FakeKnowledgeService extends KnowledgeService {
  const _FakeKnowledgeService();

  @override
  Future<List<KbItem>> listKB(String space) async => const [];
}

class _MutableKnowledgeService extends KnowledgeService {
  _MutableKnowledgeService(
    List<KbItem> items, {
    this.documents = const []
  }) : items = List.of(items);

  final List<KbItem> items;
  final List<KbDocument> documents;
  final List<({String uuid, String name})> renameCalls = [];
  final List<String> deleteCalls = [];
  final List<({String kbUuid, String fileName})> uploadCalls = [];
  int listDocumentsCalls = 0;

  @override
  Future<List<KbItem>> listKB(String space) async => List.of(items);

  @override
  Future<List<KbFolder>> listFolders({required String kbUuid}) async =>
      const [];

  @override
  Future<({List<KbDocument> items, int total})> listDocuments({
    required String kbUuid,
    String status = '',
    String kbFolderUuid = '',
    int page = 1,
    int pageSize = 50,
  }) async {
    listDocumentsCalls += 1;
    return (items: documents, total: documents.length);
  }

  @override
  Future<KbDocument> uploadDocument({
    required String kbUuid,
    required String filePath,
    required String fileName,
    String kbFolderUuid = '',
  }) async {
    uploadCalls.add((kbUuid: kbUuid, fileName: fileName));
    final index = items.indexWhere((item) => item.uuid == kbUuid);
    final current = items[index];
    items[index] = KbItem(
      uuid: current.uuid,
      name: current.name,
      scope: current.scope,
      status: current.status,
      spaceKind: current.spaceKind,
      visibility: current.visibility,
      totalDocuments: current.totalDocuments + 1,
      canWrite: current.canWrite,
      agentId: current.agentId,
      embeddingModel: current.embeddingModel,
      avatarUrl: current.avatarUrl,
    );
    final now = DateTime(2026, 7, 22);
    return KbDocument(
      uuid: 'doc-${uploadCalls.length}',
      kbUuid: kbUuid,
      fileUuid: 'file-${uploadCalls.length}',
      fileName: fileName,
      kbFolderUuid: kbFolderUuid,
      mimeType: fileName.endsWith('.pdf')
          ? 'application/pdf'
          : 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      sizeBytes: 128,
      source: 'kb_upload',
      status: 'ready',
      chunksCount: 1,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<KbItem> renameKB({
    required String kbUuid,
    required String name,
  }) async {
    renameCalls.add((uuid: kbUuid, name: name));
    final index = items.indexWhere((item) => item.uuid == kbUuid);
    final current = items[index];
    final renamed = KbItem(
      uuid: current.uuid,
      name: name,
      scope: current.scope,
      status: current.status,
      spaceKind: current.spaceKind,
      visibility: current.visibility,
      totalDocuments: current.totalDocuments,
      canWrite: current.canWrite,
      agentId: current.agentId,
      embeddingModel: current.embeddingModel,
      avatarUrl: current.avatarUrl,
    );
    items[index] = renamed;
    return renamed;
  }

  @override
  Future<void> deleteKB({required String kbUuid}) async {
    deleteCalls.add(kbUuid);
    items.removeWhere((item) => item.uuid == kbUuid);
  }
}

class _SlowTreeDriveService extends DriveService {
  _SlowTreeDriveService(this.treeGate);

  final Completer<void> treeGate;

  @override
  Future<DriveBootstrap> bootstrap() async => const DriveBootstrap(
        personal: DriveSpace(
            uuid: _FakeDriveService.personalUuid,
            kind: 'personal',
            name: '',
            status: 'active'),
        tenant: null,
        departments: [],
        shared: [],
      );

  @override
  Future<List<DriveFolder>> folderTree(String spaceUuid) async {
    await treeGate.future;
    return const [
      DriveFolder(
        uuid: 'late-folder',
        name: '延迟目录',
        kind: 'regular',
        parentId: '',
        path: '/延迟目录/',
        isSystem: false,
      ),
    ];
  }
}

class _RefreshableTreeDriveService extends DriveService {
  _RefreshableTreeDriveService(this.refreshGate);

  final Completer<void> refreshGate;
  int treeCalls = 0;

  @override
  Future<DriveBootstrap> bootstrap() async => const DriveBootstrap(
        personal: DriveSpace(
            uuid: _FakeDriveService.personalUuid,
            kind: 'personal',
            name: '',
            status: 'active'),
        tenant: null,
        departments: [],
        shared: [],
      );

  @override
  Future<List<DriveFolder>> folderTree(String spaceUuid) async {
    treeCalls += 1;
    if (treeCalls == 1) {
      return const [
        DriveFolder(
          uuid: 'cached-folder',
          name: '缓存目录',
          kind: 'regular',
          parentId: '',
          path: '/缓存目录/',
          isSystem: false,
        ),
      ];
    }
    await refreshGate.future;
    return const [
      DriveFolder(
        uuid: 'fresh-folder',
        name: '后台刷新目录',
        kind: 'regular',
        parentId: '',
        path: '/后台刷新目录/',
        isSystem: false,
      ),
    ];
  }
}

void main() {
  Future<void> secondaryClick(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(tester.getCenter(finder));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets(
      'drive sidebar renders 我的空间 / 共享空间 / 云盘 / 知识库 / 运维部 / 数字员工 (no infinite loading)',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(const _FakeDriveService()),
          knowledgeServiceProvider
              .overrideWithValue(const _FakeKnowledgeService()),
        ],
        child: const MaterialApp(home: DrivePage()),
      ),
    );

    // 初始应是骨架屏，避免空白页或跳动的 loading spinner。
    expect(find.byType(DriveInitialSkeleton), findsOneWidget);

    // 等 bootstrap + folderTree 解析完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 树解析完成后骨架屏消失。
    expect(find.byType(DriveInitialSkeleton), findsNothing,
        reason: 'tree resolved → no infinite skeleton');

    // 侧栏节点:
    // - 两个顶层桶:我的空间 / 共享空间(各一个),二级保留 云盘 / 知识库。
    expect(find.text('我的空间'), findsOneWidget);
    expect(find.text('共享空间'), findsOneWidget);
    //   "云盘" 3 处:sidebar 页头标题 + 我的空间.云盘 + 共享空间.云盘。
    expect(find.text('云盘'), findsNWidgets(3));
    expect(find.text('知识库'), findsNWidgets(2));
    // - 运维部 是 fake bootstrap 返回的 department space,作为共享云盘下的
    //   协作文件夹节点,**不再作为顶层桶**。
    expect(find.text('运维部'), findsOneWidget);
    // - de_root「数字员工」在「我的空间 / 云盘」下默认展开可见。
    expect(find.text('数字员工'), findsWidgets);
    await tester.tap(find.text('知识库').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无共享知识库'), findsNothing);
    // - 回收站入口(F06 基础设置 slice)固定在侧栏底部可见。
    expect(find.text('我的收藏'), findsOneWidget);
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏文件'), findsOneWidget);
    expect(find.text('回收站'), findsOneWidget);
  });

  testWidgets('drive page renders after bootstrap before folder trees finish',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final gate = Completer<void>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(_SlowTreeDriveService(gate)),
          knowledgeServiceProvider
              .overrideWithValue(const _FakeKnowledgeService()),
        ],
        child: const MaterialApp(home: DrivePage()),
      ),
    );

    expect(find.byType(DriveInitialSkeleton), findsOneWidget);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(DriveInitialSkeleton), findsNothing);
    expect(find.text('我的空间'), findsOneWidget);
    expect(find.text('共享空间'), findsOneWidget);
    expect(find.text('延迟目录'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('延迟目录'), findsOneWidget);
  });

  testWidgets('shared drive root files use table header and row action menu',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final driveService = _FavoriteMutationDriveService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(driveService),
          knowledgeServiceProvider
              .overrideWithValue(const _FakeKnowledgeService()),
        ],
        child: MaterialApp(
          builder: BotToastInit(),
          home: const DrivePage()
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    expect(find.text('3月cursor.pdf'), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('修改日期'), findsOneWidget);
    expect(find.text('操作'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.ellipsis), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(
      driveService.addFavoriteCalls,
      [
        (
          targetKind: 'drive_file',
          targetUuid: 'shared-file-pdf',
          kbUuid: ''),

      ]
    );
  });

  testWidgets('drive root folders use table header and folder action menu',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(const _FakeDriveService()),
          knowledgeServiceProvider
              .overrideWithValue(const _FakeKnowledgeService()),
        ],
        child: const MaterialApp(home: DrivePage()),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('云盘').at(1));
    await tester.pumpAndSettle();

    expect(find.text('hi'), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('修改日期'), findsOneWidget);
    expect(find.text('操作'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.ellipsis), findsOneWidget);
  });

  testWidgets('recycle files use drive file icon and visible action column',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(const _FakeDriveService()),
          knowledgeServiceProvider
              .overrideWithValue(const _FakeKnowledgeService()),
        ],
        child: const MaterialApp(home: DrivePage()),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();

    expect(find.text('0q5ptoTD8.png'), findsOneWidget);
    expect(find.text('文件路径'), findsOneWidget);
    expect(find.text('我的空间 / 云盘 / hu12'), findsOneWidget);
    expect(find.text('删除时间'), findsOneWidget);
    expect(find.text('删除者'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('操作'), findsOneWidget);
    expect(find.byType(DriveFileIcon), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.doc_text_fill), findsNothing);
    expect(find.byIcon(CupertinoIcons.ellipsis), findsOneWidget);
  });

  testWidgets('drive page reuses cached tree and refreshes after returning',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final gate = Completer<void>();
    final service = _RefreshableTreeDriveService(gate);
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(service),
      knowledgeServiceProvider.overrideWithValue(const _FakeKnowledgeService()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DrivePage()),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('缓存目录'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DrivePage()),
      ),
    );
    await tester.pump();

    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('缓存目录'), findsOneWidget);
    expect(find.text('后台刷新目录'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('后台刷新目录'), findsOneWidget);
    expect(find.text('缓存目录'), findsNothing);
  });

  testWidgets('writable knowledge base root can be renamed from sidebar menu',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = _MutableKnowledgeService(const [
      KbItem(
        uuid: 'kb-writable',
        name: '项目知识库',
        scope: 'personal',
        status: 'active',
        spaceKind: 'personal',
        canWrite: true,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(const _FakeDriveService()),
          knowledgeServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          builder: BotToastInit(),
          home: const DrivePage()
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await secondaryClick(tester, find.text('项目知识库'));
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名知识库'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '项目资料库');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(service.renameCalls, [(uuid: 'kb-writable', name: '项目资料库')]);
    expect(find.text('项目资料库'), findsOneWidget);
    expect(find.text('项目知识库'), findsNothing);
  });

  testWidgets('read-only knowledge base root has no mutation menu',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = _MutableKnowledgeService(const [
      KbItem(
        uuid: 'kb-readonly',
        name: '只读知识库',
        scope: 'personal',
        status: 'active',
        spaceKind: 'personal',
        canWrite: false,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(const _FakeDriveService()),
          knowledgeServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: DrivePage()),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await secondaryClick(tester, find.text('只读知识库'));

    expect(find.text('重命名'), findsNothing);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('knowledge document action menu exposes favorite',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final driveService = _FavoriteMutationDriveService();
    final now = DateTime(2026, 7, 24);
    final service = _MutableKnowledgeService(
      const [
        KbItem(
          uuid: 'kb-favorite',
          name: '收藏测试知识库',
          scope: 'personal',
          status: 'active',
          spaceKind: 'personal',
          canWrite: true,
        ),
      ],
      documents: [
        KbDocument(
          uuid: 'doc-favorite',
          kbUuid: 'kb-favorite',
          fileUuid: '',
          fileName: '制度.pdf',
          kbFolderUuid: '',
          mimeType: 'application/pdf',
          sizeBytes: 1024,
          source: 'kb_upload',
          status: 'ready',
          chunksCount: 1,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveServiceProvider.overrideWithValue(driveService),
          knowledgeServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          builder: BotToastInit(),
          home: const DrivePage()
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('收藏测试知识库'));
    await tester.pumpAndSettle();
    expect(find.text('制度.pdf'), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis).last);
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(
      driveService.addFavoriteCalls,
      [
        (
          targetKind: 'kb_document',
          targetUuid: 'doc-favorite',
          kbUuid: 'kb-favorite',
        )
      ]
    );
  });

  for (final fileName in ['退款规则.pdf', '产品介绍.pptx']) {
    testWidgets(
        'knowledge root upload $fileName refreshes KB count without reading disposed document provider',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _MutableKnowledgeService(const [
        KbItem(
          uuid: 'kb-upload',
          name: '上传目标',
          scope: 'personal',
          status: 'active',
          spaceKind: 'personal',
          canWrite: true,
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            driveServiceProvider.overrideWithValue(const _FakeDriveService()),
            knowledgeServiceProvider.overrideWithValue(service),
            knowledgeDocumentPickerProvider
                .overrideWithValue(() async => XFile('/tmp/$fileName')),
          ],
          child: MaterialApp(
            builder: BotToastInit(),
            home: const DrivePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.text('知识库').first);
      await tester.pumpAndSettle();
      expect(find.text('0 个文档'), findsOneWidget);

      final importMenu = find.ancestor(
        of: find.text('导入'),
        matching: find.byType(UiDropdownMenu<String>),
      );
      await tester.tap(importMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地上传'));
      await tester.pumpAndSettle();
      expect(find.text('选择知识库'), findsOneWidget);

      await tester.tap(find.text('上传目标').last);
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(service.uploadCalls, [(kbUuid: 'kb-upload', fileName: fileName)]);
      expect(service.listDocumentsCalls, 0,
          reason: '根列表没有订阅文档 provider，不应创建并刷新它');
      expect(find.text('1 个文档'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'deleting selected knowledge base returns to knowledge root and reloads list',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = _MutableKnowledgeService(const [
      KbItem(
        uuid: 'kb-delete',
        name: '待删除知识库',
        scope: 'personal',
        status: 'active',
        spaceKind: 'personal',
        canWrite: true,
      ),
    ]);
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(const _FakeDriveService()),
      knowledgeServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: BotToastInit(),
          home: const DrivePage()
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('待删除知识库'));
    await tester.pumpAndSettle();
    expect(container.read(driveSelectionProvider).kind, DriveSelectionKind.kb);

    await secondaryClick(tester, find.text('待删除知识库').first);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除知识库'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(service.deleteCalls, ['kb-delete']);
    expect(find.text('待删除知识库'), findsNothing);
    expect(
        container.read(driveSelectionProvider).kind, DriveSelectionKind.kbRoot);
    expect(container.read(selectedSpaceProvider), 'personal');
  });
}
