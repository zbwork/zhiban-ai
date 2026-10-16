import 'dart:async';

import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/services/drive_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

final driveServiceProvider =
    Provider<DriveService>((ref) => const DriveService());

/// 当前选中的 Space —— 真实 space UUID。默认空(进页后由 bootstrap/选中行回填)。
final selectedSpaceProvider = StateProvider<String>((ref) => '');

/// 选中项类型(drive 根 / drive 目录 / KB 根 / KB / KB 目录 / 最近使用 / 收藏 / 回收站)。
enum DriveSelectionKind {
  none,
  driveRoot,
  driveFolder,
  kbRoot,
  kb,
  kbFolder,
  recent,
  favorite,
  recycle
}

/// 当前侧栏选中项。drive 目录选中时 [folderUuid] 非空;
/// 知识库选中时 [kbUuid] 非空;KB 目录选中时 [kbFolderUuid] 非空。
class DriveSelection {
  const DriveSelection({
    this.kind = DriveSelectionKind.none,
    this.folderUuid = '',
    this.kbUuid = '',
    this.kbFolderUuid = '',
  });

  final DriveSelectionKind kind;
  final String folderUuid;
  final String kbUuid;
  final String kbFolderUuid;

  static const empty = DriveSelection();
}

final driveSelectionProvider =
    StateProvider<DriveSelection>((ref) => DriveSelection.empty);

/// 当前选中目录的 UUID(若选中的不是目录则为空)。
final selectedFolderProvider = Provider<String>((ref) {
  final s = ref.watch(driveSelectionProvider);
  return s.kind == DriveSelectionKind.driveFolder ? s.folderUuid : '';
});

/// drive 页加载状态聚合。trees 按真实 space UUID 存各空间的扁平目录列表。
class DriveTreeState {
  const DriveTreeState({
    this.bootstrap,
    this.treesBySpaceUuid = const {}
  });

  final DriveBootstrap? bootstrap;
  final Map<String, List<DriveFolder>> treesBySpaceUuid;

  DriveSpace? get personal => bootstrap?.personal;
  List<DriveSpace> get orgSpaces => bootstrap?.orgSpaces ?? const [];
  List<DriveSpace> get allSpaces => bootstrap?.allSpaces ?? const [];

  List<DriveFolder> foldersFor(String spaceUuid) =>
      treesBySpaceUuid[spaceUuid] ?? const [];

  DriveTreeState copyWith({
    DriveBootstrap? bootstrap,
    Map<String, List<DriveFolder>>? treesBySpaceUuid,
  }) =>
      DriveTreeState(
        bootstrap: bootstrap ?? this.bootstrap,
        treesBySpaceUuid: treesBySpaceUuid ?? this.treesBySpaceUuid,
      );
}

class DriveTreeNotifier extends AsyncNotifier<DriveTreeState> {
  bool _refreshing = false;

  @override
  Future<DriveTreeState> build() async {
    final svc = ref.read(driveServiceProvider);
    // Do not leave a cold page in AsyncLoading forever when the underlying
    // socket never completes a request.
    final bootstrap = await svc.bootstrap().timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('云盘初始化超时'),
        );
    final initial = DriveTreeState(bootstrap: bootstrap);
    if (!ref.mounted) return initial;
    unawaited(_loadSpaceTrees(bootstrap));
    return initial;
  }

  Future<void> _loadSpaceTrees(DriveBootstrap bootstrap) async {
    if (!ref.mounted) return;
    final svc = ref.read(driveServiceProvider);
    final spaces = [
      for (final sp in bootstrap.allSpaces)
        if (sp.uuid.isNotEmpty) sp,
    ];
    if (spaces.isEmpty) return;

    await Future.wait(
      spaces.map((sp) => _loadOneSpaceTree(
            spaceUuid: sp.uuid,
            bootstrap: bootstrap,
            svc: svc,
          )),
    );
  }

  Future<void> _loadOneSpaceTree({
    required String spaceUuid,
    required DriveBootstrap bootstrap,
    required DriveService svc,
  }) async {
    List<DriveFolder> list;
    try {
      list = await svc.folderTree(spaceUuid);
    } catch (_) {
      final current = state.value;
      if (current != null && current.treesBySpaceUuid.containsKey(spaceUuid)) {
        return;
      }
      list = const <DriveFolder>[];
    }
    if (!ref.mounted) return;
    final current = state.value ?? DriveTreeState(bootstrap: bootstrap);
    final next = Map<String, List<DriveFolder>>.from(current.treesBySpaceUuid);
    next[spaceUuid] = list;
    state = AsyncData(current.copyWith(
      bootstrap: current.bootstrap ?? bootstrap,
      treesBySpaceUuid: next,
    ));
  }

  /// 页面级 stale-while-revalidate:已有树立即可用,后台刷新 bootstrap + tree。
  Future<void> refreshSilently() async {
    if (_refreshing) return;
    final current = state.value;
    if (current == null || current.bootstrap == null) return;
    _refreshing = true;
    try {
      final svc = ref.read(driveServiceProvider);
      final bootstrap = await svc.bootstrap();
      if (!ref.mounted) return;
      final latest = state.value ?? current;
      state = AsyncData(latest.copyWith(bootstrap: bootstrap));
      await _loadSpaceTrees(bootstrap);
    } catch (_) {
      // 后台刷新失败时保留已渲染树,避免用户切回云盘出现整页错误/空白。
    } finally {
      _refreshing = false;
    }
  }

  Future<void> reloadSpace(String spaceUuid) async {
    if (spaceUuid.isEmpty) return;
    final current = state.value ?? const DriveTreeState();
    final svc = ref.read(driveServiceProvider);
    final list = await svc.folderTree(spaceUuid);
    final next = Map<String, List<DriveFolder>>.from(current.treesBySpaceUuid);
    next[spaceUuid] = list;
    state = AsyncData(current.copyWith(treesBySpaceUuid: next));
  }

  /// 在所有 space 树里找 uuid 对应的 DriveFolder。找不到返 null。
  DriveFolder? findFolder(String uuid) {
    if (uuid.isEmpty) return null;
    final st = state.value;
    if (st == null) return null;
    for (final list in st.treesBySpaceUuid.values) {
      for (final f in list) {
        if (f.uuid == uuid) return f;
      }
    }
    return null;
  }

  /// 找某 folder 所属的 space UUID(用于 mutate 后定位要 reload 的空间)。
  String spaceUuidOfFolder(String folderUuid) {
    final st = state.value;
    if (st == null) return '';
    for (final entry in st.treesBySpaceUuid.entries) {
      for (final f in entry.value) {
        if (f.uuid == folderUuid) return entry.key;
      }
    }
    return '';
  }

  int _sortFolders(DriveFolder a, DriveFolder b) {
    if (a.sort != b.sort) return a.sort.compareTo(b.sort);
    // 系统目录优先于用户目录
    if (a.isSystem != b.isSystem) return a.isSystem ? -1 : 1;
    return a.name.compareTo(b.name);
  }

  /// 找某 space 根级(parentId 为空)的目录列表。
  List<DriveFolder> rootFoldersOf(String spaceUuid) {
    final st = state.value;
    if (st == null) return const [];
    return st.foldersFor(spaceUuid).where((f) => f.parentId.isEmpty).toList()
      ..sort(_sortFolders);
  }

  /// 列出某 space 下某父目录的直接子目录。
  List<DriveFolder> childrenOf(String spaceUuid, String parentUuid) {
    final st = state.value;
    if (st == null) return const [];
    return st
        .foldersFor(spaceUuid)
        .where((f) => f.parentId == parentUuid)
        .toList()
      ..sort(_sortFolders);
  }
}

final driveTreeProvider =
    AsyncNotifierProvider<DriveTreeNotifier, DriveTreeState>(
        DriveTreeNotifier.new, retry: (_, __) => null);

/// 当前选中目录的子目录 + 文件列表。
const int _driveContentPageSize = 50;

class DriveContentState {
  const DriveContentState({this.children, this.page = 1, this.hasMore = false});

  /// 累计已加载的子目录 + 文件（按 uuid 去重合并各页）。
  final FolderChildren? children;
  final int page;
  final bool hasMore;
}

class DriveContentNotifier extends AsyncNotifier<DriveContentState> {
  DriveContentNotifier(this.folderUuid);
  final String folderUuid;

  // loadMore 去重；按 folderUuid 实例隔离（family 每个目录一个 notifier）。
  bool _loadingMore = false;

  @override
  Future<DriveContentState> build() async {
    if (folderUuid.isEmpty) {
      return const DriveContentState();
    }
    final svc = ref.read(driveServiceProvider);
    final children = await svc.listFolderChildren(
      folderUuid,
      page: 1,
      pageSize: _driveContentPageSize,
    );
    return DriveContentState(
      children: children,
      page: 1,
      hasMore: _hasMore(1, children),
    );
  }

  Future<void> reload() async {
    if (folderUuid.isEmpty) return;
    final svc = ref.read(driveServiceProvider);
    state = const AsyncLoading();
    try {
      final children = await svc.listFolderChildren(
        folderUuid,
        page: 1,
        pageSize: _driveContentPageSize,
      );
      state = AsyncData(DriveContentState(
        children: children,
        page: 1,
        hasMore: _hasMore(1, children),
      ));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// 上拉加载下一页：拉 page+1 的 folders+files，按 uuid 去重合并到已加载集合。
  /// 失败抛出给调用方（列表层负责 toast/footer），不污染已加载数据。
  Future<void> loadMore() async {
    if (folderUuid.isEmpty || _loadingMore) return;
    final current = state.asData?.value;
    if (current == null || current.children == null || !current.hasMore) return;
    _loadingMore = true;
    try {
      final nextPage = current.page + 1;
      final svc = ref.read(driveServiceProvider);
      final more = await svc.listFolderChildren(
        folderUuid,
        page: nextPage,
        pageSize: _driveContentPageSize,
      );
      final merged = _mergeByUuid(current.children!, more);
      state = AsyncData(DriveContentState(
        children: merged,
        page: nextPage,
        hasMore: _hasMore(nextPage, more),
      ));
    } finally {
      _loadingMore = false;
    }
  }

  // 后端 folders 与 files 都按同一 page 分页，但 total 只统计文件数（folders 无 total）。
  // 还有更多 = 文件还没拉完(page*size < total) 或 本页 folders 拉满(可能还有下一页目录)。
  bool _hasMore(int page, FolderChildren pageData) {
    final moreFiles = page * _driveContentPageSize < pageData.total;
    final foldersPageFull = pageData.folders.length >= _driveContentPageSize;
    return moreFiles || foldersPageFull;
  }

  FolderChildren _mergeByUuid(FolderChildren acc, FolderChildren more) {
    final folderMap = <String, DriveFolder>{
      for (final f in acc.folders) f.uuid: f,
    };
    for (final f in more.folders) {
      folderMap[f.uuid] = f;
    }
    final fileMap = <String, DriveFile>{
      for (final f in acc.files) f.uuid: f
    };
    for (final f in more.files) {
      fileMap[f.uuid] = f;
    }
    return FolderChildren(
      folders: folderMap.values.toList(),
      files: fileMap.values.toList(),
      total: more.total,
    );
  }
}

final driveContentProvider = AsyncNotifierProvider.autoDispose
    .family<DriveContentNotifier, DriveContentState, String>(
  DriveContentNotifier.new,
);

/// 「最近使用」入口数据。
class DriveRecentFilesNotifier extends AsyncNotifier<List<DriveFile>> {
  @override
  Future<List<DriveFile>> build() async {
    final svc = ref.read(driveServiceProvider);
    return svc.listRecentFiles(limit: 100);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    try {
      final list =
          await ref.read(driveServiceProvider).listRecentFiles(limit: 100);
      state = AsyncData(list);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final driveRecentFilesProvider = AsyncNotifierProvider.autoDispose<
    DriveRecentFilesNotifier, List<DriveFile>>(DriveRecentFilesNotifier.new);

/// 「我的收藏」入口数据。
class DriveFavoritesNotifier extends AsyncNotifier<List<DriveFavoriteItem>> {
  @override
  Future<List<DriveFavoriteItem>> build() async {
    return ref.read(driveServiceProvider).listFavorites(limit: 200);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    try {
      final list =
          await ref.read(driveServiceProvider).listFavorites(limit: 200);
      state = AsyncData(list);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final driveFavoritesProvider = AsyncNotifierProvider.autoDispose<
    DriveFavoritesNotifier, List<DriveFavoriteItem>>(
  DriveFavoritesNotifier.new
);

/// 聊天附件列表 —— 给「导入聊天文件」弹框用。family 参数为会话 uuid;空=跨所有会话。
class DriveChatAttachmentsNotifier extends AsyncNotifier<List<ChatAttachment>> {
  DriveChatAttachmentsNotifier(this.conversationUuid);
  final String conversationUuid;

  @override
  Future<List<ChatAttachment>> build() async {
    final svc = ref.read(driveServiceProvider);
    return svc.listChatAttachments(
      conversationId: conversationUuid.isEmpty ? null : conversationUuid,
      limit: 50,
    );
  }
}

final driveChatAttachmentsProvider = AsyncNotifierProvider.autoDispose
    .family<DriveChatAttachmentsNotifier, List<ChatAttachment>, String>(
  DriveChatAttachmentsNotifier.new,
);

/// 回收站列表(F06 基础设置 slice)。autoDispose:离开页或重打开自动刷新。
class DriveRecycleNotifier extends AsyncNotifier<List<RecycleItem>> {
  @override
  Future<List<RecycleItem>> build() async {
    return ref.read(driveServiceProvider).listRecycle(limit: 100);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    try {
      final list = await ref.read(driveServiceProvider).listRecycle(limit: 100);
      state = AsyncData(list);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  void removeLocal(String recycleUuid) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.where((item) => item.uuid != recycleUuid).toList(growable: false),
    );
  }
}

final driveRecycleProvider =
    AsyncNotifierProvider.autoDispose<DriveRecycleNotifier, List<RecycleItem>>(
        DriveRecycleNotifier.new);

final driveRootFilesProvider = FutureProvider.autoDispose
    .family<List<DriveFile>, String>((ref, spaceUuid) {
  if (spaceUuid.isEmpty || spaceUuid == 'org') return const <DriveFile>[];
  return ref.read(driveServiceProvider).listRootFiles(spaceUuid);
});

/// 共享文件夹协作者列表(F06 基础设置 slice)。
///
/// family 参数兼容两种 key:
/// - `space_uuid`:共享空间/云盘第一层协作文件夹
/// - `folder:<folder_uuid>`:其下普通子目录,列表为 effective members
class DriveSpaceMembersNotifier extends AsyncNotifier<List<SpaceMember>> {
  DriveSpaceMembersNotifier(this.targetKey);
  final String targetKey;

  bool get _isFolder => targetKey.startsWith('folder:');
  String get _uuid =>
      _isFolder ? targetKey.substring('folder:'.length) : targetKey;

  @override
  Future<List<SpaceMember>> build() async {
    if (_uuid.isEmpty) return const [];
    final service = ref.read(driveServiceProvider);
    return _isFolder
        ? service.listFolderMembers(_uuid)
        : service.listSpaceMembers(_uuid);
  }

  Future<void> reload() async {
    if (_uuid.isEmpty) return;
    final previous = state.value;
    if (previous == null) {
      state = const AsyncLoading();
    }
    try {
      final service = ref.read(driveServiceProvider);
      final list = _isFolder
          ? await service.listFolderMembers(_uuid)
          : await service.listSpaceMembers(_uuid);
      state = AsyncData(list);
    } catch (e, st) {
      if (previous == null) {
        state = AsyncError(e, st);
      }
    }
  }

  void replaceLocal(List<SpaceMember> members) {
    state = AsyncData(List<SpaceMember>.of(members));
  }

  void updateRoleLocal(String accountUuid, String role) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final member in current)
        if (member.accountUuid == accountUuid)
          SpaceMember(accountUuid: member.accountUuid, role: role)
        else
          member,
    ]);
  }

  void removeLocal(String accountUuid) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final member in current)
        if (member.accountUuid != accountUuid) member,
    ]);
  }
}

final driveSpaceMembersProvider = AsyncNotifierProvider.autoDispose
    .family<DriveSpaceMembersNotifier, List<SpaceMember>, String>(
  DriveSpaceMembersNotifier.new,
);
