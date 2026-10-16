import 'package:zhiban_client/pages/workbench/models/workbench_app.dart';
import 'package:zhiban_client/pages/workbench/models/workbench_app_category.dart';
import 'package:zhiban_client/pages/workbench/services/workbench_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final workbenchServiceProvider = Provider<WorkbenchService>((ref) {
  return WorkbenchService();
});

final workbenchAppsProvider =
    AsyncNotifierProvider<WorkbenchAppsNotifier, WorkbenchAppsState>(
  WorkbenchAppsNotifier.new,
);

class WorkbenchAppsNotifier extends AsyncNotifier<WorkbenchAppsState> {
  @override
  Future<WorkbenchAppsState> build() async {
    return _loadApps();
  }

  Future<void> refreshApps() async {
    final previous = state.asData?.value;
    if (previous == null) {
      state = const AsyncLoading();
    } else {
      state = AsyncData(previous.copyWith(isRefreshing: true));
    }

    try {
      final nextState = await _loadApps(ignoreCache: true);
      state = AsyncData(nextState);
    } catch (error, stackTrace) {
      if (previous != null) {
        state = AsyncData(previous.copyWith(isRefreshing: false));
      } else {
        state = AsyncError(error, stackTrace);
      }
    }
  }

  Future<WorkbenchAppsState> _loadApps({bool ignoreCache = false}) async {
    final service = ref.read(workbenchServiceProvider);

    List<WorkbenchAppCategory>? cached;
    if (!ignoreCache) {
      cached = await service.getCachedApps();
    }

    try {
      final remote = await service.fetchApps();
      await service.cacheApps(remote);
      return WorkbenchAppsState(
        categories: remote,
        isFromCache: false,
        isRefreshing: false,
      );
    } catch (_) {
      if (cached != null) {
        return WorkbenchAppsState(
          categories: cached,
          isFromCache: true,
          isRefreshing: false,
        );
      }
      rethrow;
    }
  }
}

class WorkbenchAppsState {
  const WorkbenchAppsState({
    required this.categories,
    required this.isFromCache,
    required this.isRefreshing,
  });

  const WorkbenchAppsState.loading()
      : categories = const [],
        isFromCache = false,
        isRefreshing = true;

  final List<WorkbenchAppCategory> categories;
  final bool isFromCache;
  final bool isRefreshing;

  List<WorkbenchApp> get apps => [
        for (final category in categories) ...category.apps
      ]..sort((a, b) => a.order.compareTo(b.order));

  WorkbenchAppsState copyWith({
    List<WorkbenchAppCategory>? categories,
    bool? isFromCache,
    bool? isRefreshing,
  }) {
    return WorkbenchAppsState(
      categories: categories ?? this.categories,
      isFromCache: isFromCache ?? this.isFromCache,
      isRefreshing: isRefreshing ?? this.isRefreshing,
    );
  }
}
