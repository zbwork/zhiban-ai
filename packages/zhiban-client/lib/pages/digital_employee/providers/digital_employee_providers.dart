import 'package:riverpod/riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:zhiban_core/chat/chat_models.dart';

import '../services/digital_employee_service.dart';

final digitalEmployeeServiceProvider = Provider<OpenClawDigitalEmployeeService>(
    (_) => OpenClawDigitalEmployeeService());

final digitalEmployeeSearchProvider =
    NotifierProvider<DigitalEmployeeSearchNotifier, String>(
  DigitalEmployeeSearchNotifier.new,
);

class DigitalEmployeeSearchNotifier extends Notifier<String> {
  @override
  String build() => '';

  void setKeyword(String keyword) {
    state = keyword;
  }
}

final digitalEmployeeFilterProvider =
    StateProvider<DigitalEmployeeCatalogFilter>(
  (_) => DigitalEmployeeCatalogFilter.all,
);

final digitalEmployeeCatalogProvider = AsyncNotifierProvider<
    DigitalEmployeeCatalogNotifier, DigitalEmployeeCatalog>(
  DigitalEmployeeCatalogNotifier.new
);

class DigitalEmployeeCatalogNotifier
    extends AsyncNotifier<DigitalEmployeeCatalog> {
  @override
  Future<DigitalEmployeeCatalog> build() async {
    final keyword = ref.watch(digitalEmployeeSearchProvider);
    return ref
        .read(digitalEmployeeServiceProvider)
        .listCatalog(keyword: keyword);
  }

  Future<void> refresh({
    AgentItem? preservePersonalAgent,
    bool keepPreviousOnError = false,
  }) async {
    try {
      final keyword = ref.read(digitalEmployeeSearchProvider);
      var catalog = await ref
          .read(digitalEmployeeServiceProvider)
          .listCatalog(keyword: keyword);
      if (preservePersonalAgent != null) {
        catalog = catalog.withPersonalAgent(preservePersonalAgent);
      }
      state = AsyncData(catalog);
    } catch (error, stackTrace) {
      if (!keepPreviousOnError) {
        state = AsyncError(error, stackTrace);
      }
    }
  }

  void upsertPersonalAgent(AgentItem agent) {
    final current = state.asData?.value;
    if (current == null) {
      state = AsyncData(DigitalEmployeeCatalog(
        personal: [DigitalEmployeeCatalogItem.personal(agent)],
        enterprise: const [],
      ));
      return;
    }
    state = AsyncData(current.withPersonalAgent(agent));
  }
}

final filteredDigitalEmployeesProvider =
    Provider<List<DigitalEmployeeCatalogItem>>((ref) {
  // 搜索/刷新重载期间用 .value 保留旧列表（asData 在 Loading 态恒为
  // null，会让网格在每次输入后闪空）。
  final catalog = ref.watch(digitalEmployeeCatalogProvider).value;
  if (catalog == null) return const <DigitalEmployeeCatalogItem>[];
  final filter = ref.watch(digitalEmployeeFilterProvider);
  return catalog.itemsFor(filter);
});
