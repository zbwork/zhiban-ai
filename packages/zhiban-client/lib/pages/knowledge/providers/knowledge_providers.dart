import 'package:file_selector/file_selector.dart' show XFile;
import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:zhiban_client/pages/knowledge/services/knowledge_service.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

final knowledgeServiceProvider =
    Provider<KnowledgeService>((ref) => const KnowledgeService());

typedef KnowledgeDocumentPicker = Future<XFile?> Function();

final knowledgeDocumentPickerProvider = Provider<KnowledgeDocumentPicker>(
  (ref) => pickKnowledgeDocumentFile,
);

/// 当前选中 Space (personal | org)
final knowledgeSelectedSpaceProvider =
    StateProvider<String>((ref) => 'personal');

/// 当前选中 KB UUID
final knowledgeSelectedKBProvider = StateProvider<String>((ref) => '');

/// KB 列表(family,按 Space 拉)
class KnowledgeKBListNotifier extends AsyncNotifier<List<KbItem>> {
  KnowledgeKBListNotifier(this.space);
  final String space;

  @override
  Future<List<KbItem>> build() async {
    return ref.read(knowledgeServiceProvider).listKB(space);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    try {
      final list = await ref.read(knowledgeServiceProvider).listKB(space);
      state = AsyncData(list);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

// autoDispose:云盘页离开后,KB 列表跟着失效,下次进页面重新拉,
// 老 agent 回填 / 新 agent 创建后立即可见。
final knowledgeKBListProvider = AsyncNotifierProvider.autoDispose
    .family<KnowledgeKBListNotifier, List<KbItem>, String>(
  KnowledgeKBListNotifier.new,
);

class KnowledgeFoldersNotifier extends AsyncNotifier<List<KbFolder>> {
  KnowledgeFoldersNotifier(this.kbUuid);
  final String kbUuid;

  @override
  Future<List<KbFolder>> build() async {
    if (kbUuid.isEmpty) return const [];
    return ref.read(knowledgeServiceProvider).listFolders(kbUuid: kbUuid);
  }

  Future<void> reload() async {
    if (kbUuid.isEmpty) return;
    state = const AsyncLoading();
    try {
      state = AsyncData(
          await ref.read(knowledgeServiceProvider).listFolders(kbUuid: kbUuid));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final knowledgeFoldersProvider = AsyncNotifierProvider.autoDispose
    .family<KnowledgeFoldersNotifier, List<KbFolder>, String>(
  KnowledgeFoldersNotifier.new,
);

/// 某个 KB 的文档列表
class KnowledgeDocumentsState {
  const KnowledgeDocumentsState({
    this.items = const [],
    this.total = 0
  });

  final List<KbDocument> items;
  final int total;
}

class KnowledgeDocumentsQuery {
  const KnowledgeDocumentsQuery({
    required this.kbUuid,
    this.kbFolderUuid = ''
  });

  final String kbUuid;
  final String kbFolderUuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KnowledgeDocumentsQuery &&
          other.kbUuid == kbUuid &&
          other.kbFolderUuid == kbFolderUuid;

  @override
  int get hashCode => Object.hash(kbUuid, kbFolderUuid);
}

class KnowledgeDocumentsNotifier
    extends AsyncNotifier<KnowledgeDocumentsState> {
  KnowledgeDocumentsNotifier(this.query);
  final KnowledgeDocumentsQuery query;

  @override
  Future<KnowledgeDocumentsState> build() async {
    final kbUuid = query.kbUuid;
    if (kbUuid.isEmpty) return const KnowledgeDocumentsState();
    final res = await ref.read(knowledgeServiceProvider).listDocuments(
          kbUuid: kbUuid,
          kbFolderUuid: query.kbFolderUuid
        );
    return KnowledgeDocumentsState(items: res.items, total: res.total);
  }

  Future<void> reload() async {
    final kbUuid = query.kbUuid;
    if (kbUuid.isEmpty) return;
    state = const AsyncLoading();
    try {
      final res = await ref.read(knowledgeServiceProvider).listDocuments(
            kbUuid: kbUuid,
            kbFolderUuid: query.kbFolderUuid
          );
      state = AsyncData(
          KnowledgeDocumentsState(items: res.items, total: res.total));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final knowledgeDocumentsProvider = AsyncNotifierProvider.autoDispose.family<
    KnowledgeDocumentsNotifier,
    KnowledgeDocumentsState,
    KnowledgeDocumentsQuery>(
  KnowledgeDocumentsNotifier.new
);
