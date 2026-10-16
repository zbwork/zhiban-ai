import '../models/ai_provider_config.dart';
import '../models/catalog_entry.dart';

/// 左侧服务商列表里的一行：要么是本地已落地的记录，要么是目录里还没配置过
/// 的草稿，二选一，统一成同一个排序/渲染单位。
class ProviderRow {
  const ProviderRow.local(
    AiProviderConfig this.provider, {
    String? iconAssetPath,
    bool defaultFirst = false,
    String? displayName,
  })  : catalogEntry = null,
        _localIconAssetPath = iconAssetPath,
        _localDefaultFirst = defaultFirst,
        _displayName = displayName;
  const ProviderRow.catalog(CatalogProviderEntry this.catalogEntry)
      : provider = null,
        _localIconAssetPath = null,
        _localDefaultFirst = false,
        _displayName = null;

  final AiProviderConfig? provider;
  final CatalogProviderEntry? catalogEntry;
  final bool _localDefaultFirst;
  final String? _displayName;

  /// 本地记录对应的目录 Logo——只有"从目录落地"的 provider 才有（在
  /// [sortProviderRows] 里按 [AiProviderConfig.catalogId] 查出来传进来）；
  /// 纯自定义 provider（没有 catalogId）传 null，回退首字母色块
  /// (2026-08-27 反馈：已落地的目录厂商在列表里图标不见了，只剩下字母)。
  final String? _localIconAssetPath;

  /// 排序/持久化用的稳定 key：本地记录用它的 id；还没落地的目录草稿用
  /// `catalog:<catalogId>` 前缀——跟 [ModelServiceSelection]/详情面板选中态
  /// 用的同一套约定，保持一致不各写一套。
  String get key =>
      provider != null ? provider!.id : 'catalog:${catalogEntry!.id}';

  String get name => _displayName ?? provider?.name ?? catalogEntry!.name;
  String? get iconAssetPath =>
      provider != null ? _localIconAssetPath : catalogEntry!.iconAssetPath;
  bool get enabled => provider?.enabled ?? false;
  bool get defaultFirst => catalogEntry?.defaultFirst ?? _localDefaultFirst;
}

/// 左侧服务商列表的展示顺序。
///
/// - [persistedOrder] 非空（用户拖动过，或某个服务商被启用过一次）时，按
///   这份顺序渲染；期间新出现的普通行追加在末尾。带 [ProviderRow.defaultFirst]
///   的新增目录项如果尚未出现在持久化顺序中，会先展示在第一项；用户一旦拖动
///   保存了它的位置，持久化顺序就完全接管，不再强制置顶。
/// - [persistedOrder] 为空（用户从没拖动过、也没启用过任何服务商）时，走
///   默认规则：`defaultFirst` 目录项最前，然后是已启用、未启用/未添加的
///   服务商；同一分区内部维持原始登记顺序。
/// - **顺序完全由 persistedOrder 决定，不再有"已启用必须整体排前面"这条
///   事后硬约束**（2026-09-02 反馈修正：照抄 Cherry Studio 的模型——启用
///   状态只是个独立开关，跟排序无关，拖到哪就是哪，不会被强制归位）。
///   "启用后排到最前"改成只在真正发生 false->true 跳变的那一刻挪一次
///   （见 [ProviderOrderNotifier.moveToFront]，同样照抄 Cherry Studio
///   `ProviderService.update` 里 `isEnabled` 分支 `applyMoves(anchor:
///   'first')` 的做法），而不是每次渲染都重新拆分强制排序。
List<ProviderRow> sortProviderRows({
  required List<AiProviderConfig> localProviders,
  required List<CatalogProviderEntry> catalogProviders,
  required List<String> persistedOrder,
}) {
  final catalogById = {for (final entry in catalogProviders) entry.id: entry};
  final customRows = [
    for (final p in localProviders)
      if (p.catalogId == null)
        ProviderRow.local(p,
            iconAssetPath: catalogById[p.catalogId]?.iconAssetPath),
  ];
  final localByCatalogId = <String, AiProviderConfig>{
    for (final p in localProviders)
      if (p.catalogId != null) p.catalogId!: p,
  };
  final catalogRows = [
    for (final entry in catalogProviders)
      localByCatalogId[entry.id] != null
          ? ProviderRow.local(
              localByCatalogId[entry.id]!,
              iconAssetPath: entry.iconAssetPath,
              defaultFirst: entry.defaultFirst,
            )
          : ProviderRow.catalog(entry),
  ];

  final all = [...customRows, ...catalogRows];
  final byKey = {for (final row in all) row.key: row};

  final defaultOrder = [
    for (final row in all)
      if (row.defaultFirst) row,
    for (final row in all)
      if (!row.defaultFirst && row.enabled) row,
    for (final row in all)
      if (!row.defaultFirst && !row.enabled) row,
  ];

  final baseOrder = <ProviderRow>[];
  if (persistedOrder.isEmpty) {
    baseOrder.addAll(defaultOrder);
  } else {
    final seen = <String>{};
    final persistedKeys = persistedOrder.toSet();
    for (final row in defaultOrder) {
      if (row.defaultFirst &&
          !persistedKeys.contains(row.key) &&
          seen.add(row.key)) {
        baseOrder.add(row);
      }
    }
    for (final key in persistedOrder) {
      final row = byKey[key];
      if (row != null && seen.add(row.key)) baseOrder.add(row);
    }
    for (final row in defaultOrder) {
      if (seen.add(row.key)) baseOrder.add(row);
    }
  }

  return baseOrder;
}
