/// F04 应用 (composer chip + WebView 启动) 数据模型。
///
/// 后端契约见 `docs/contracts/app-oauth2-contract.md` §1。
library;

/// 入口形态; v0.1 仅 sidePanel + fullscreen, external_browser 留 v0.2。
enum AppDisplayMode {
  sidePanel,
  fullscreen,
  externalBrowser;

  static AppDisplayMode fromString(String s) {
    switch (s) {
      case 'side_panel':
        return AppDisplayMode.sidePanel;
      case 'fullscreen':
        return AppDisplayMode.fullscreen;
      case 'external_browser':
        return AppDisplayMode.externalBrowser;
      default:
        return AppDisplayMode.sidePanel;
    }
  }
}

/// 单条应用在 composer chip 行的渲染数据。
class ConversationAppItem {
  const ConversationAppItem({
    required this.uuid,
    required this.name,
    required this.displayMode,
    this.iconUrl = '',
    this.color = '',
    this.categoryUuid = '',
    this.categoryName = '',
    this.bindingKind = 'universal',
    this.agentUuid = '',
    this.sortOrder = 0,
  });

  final String uuid;
  final String name;
  final String iconUrl;
  final String color;
  final AppDisplayMode displayMode;
  final String categoryUuid;
  final String categoryName;

  /// universal | agent_bound
  final String bindingKind;
  final String agentUuid;
  final int sortOrder;

  factory ConversationAppItem.fromJson(Map<String, dynamic> json) {
    return ConversationAppItem(
      uuid: (json['uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      iconUrl: (json['icon_url'] ?? '').toString(),
      color: (json['color'] ?? '').toString(),
      displayMode: AppDisplayMode.fromString((json['display_mode'] ?? 'side_panel').toString()),
      categoryUuid: (json['category_uuid'] ?? '').toString(),
      categoryName: (json['category_name'] ?? '').toString(),
      bindingKind: (json['binding_kind'] ?? 'universal').toString(),
      agentUuid: (json['agent_uuid'] ?? '').toString(),
      sortOrder: (json['sort_order'] is num) ? (json['sort_order'] as num).toInt() : 0,
    );
  }
}

/// /apps/{uuid}/launch 返回; launchUrl 内含一次性 code + state + iss。
class AppLaunchResult {
  const AppLaunchResult({
    required this.launchUrl,
    required this.displayMode,
    this.expiresIn = 60,
  });

  final String launchUrl;
  final AppDisplayMode displayMode;
  final int expiresIn;

  factory AppLaunchResult.fromJson(Map<String, dynamic> json) {
    return AppLaunchResult(
      launchUrl: (json['launch_url'] ?? '').toString(),
      displayMode: AppDisplayMode.fromString((json['display_mode'] ?? 'side_panel').toString()),
      expiresIn: (json['expires_in'] is num) ? (json['expires_in'] as num).toInt() : 60,
    );
  }
}
