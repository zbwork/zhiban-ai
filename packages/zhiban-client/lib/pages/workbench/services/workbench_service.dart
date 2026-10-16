import 'dart:convert';

import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/workbench/models/workbench_app_category.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String homeAppsAllApi = '/workspace/apps';

class WorkbenchService {
  static const _cacheKey = AppConfig.storageWorkbenchAppsKey;

  Future<List<WorkbenchAppCategory>> fetchApps() async {
    final response = await request.get(homeAppsAllApi);
    final body = response.data;
    final data = body is Map<String, dynamic>
        ? (body['items'] as List<dynamic>? ?? const [])
        : body as List<dynamic>;
    return data
        .map((item) =>
            WorkbenchAppCategory.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<WorkbenchAppCategory>?> getCachedApps() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached == null || cached.isEmpty) return null;

    try {
      final data = jsonDecode(cached) as List<dynamic>;
      return data
          .map((item) =>
              WorkbenchAppCategory.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> cacheApps(List<WorkbenchAppCategory> apps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey,
      jsonEncode(apps.map((item) => item.toJson()).toList()),
    );
  }
}
