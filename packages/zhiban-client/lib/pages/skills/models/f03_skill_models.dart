// f03_skill_models.dart — F03 v0.9.1 SkillHub 客户端 DTO
// docs/features/F03-skills.md §3.3。
import 'package:flutter/foundation.dart';

@immutable
class F03SkillRail {
  const F03SkillRail({
    required this.conversationUuid,
    required this.agentUuid,
    required this.chipRail,
    required this.moreDrawer,
    required this.toolRailSystem,
    required this.configVersion,
    required this.cacheTtlSeconds,
  });

  final String conversationUuid;
  final String agentUuid;
  final List<F03ChipItem> chipRail;
  final List<F03ChipItem> moreDrawer;
  final List<F03ToolRailItem> toolRailSystem;
  final String configVersion;
  final int cacheTtlSeconds;

  factory F03SkillRail.fromJson(Map<String, dynamic> j) {
    return F03SkillRail(
      conversationUuid: (j['conversation_uuid'] as String?) ?? '',
      agentUuid: (j['agent_uuid'] as String?) ?? '',
      chipRail: ((j['chip_rail'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(F03ChipItem.fromJson)
          .toList(),
      moreDrawer: ((j['more_drawer'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(F03ChipItem.fromJson)
          .toList(),
      toolRailSystem: ((j['tool_rail_system'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(F03ToolRailItem.fromJson)
          .toList(),
      configVersion: (j['config_version'] as String?) ?? '',
      cacheTtlSeconds: (j['cache_ttl_seconds'] as int?) ?? 300,
    );
  }
}

@immutable
class F03ChipItem {
  const F03ChipItem({
    required this.skillUuid,
    required this.code,
    required this.name,
    required this.iconUrl,
    required this.kind,
    required this.executionMode,
    required this.pinned,
    required this.sortOrder,
    required this.source,
    required this.defaultParams,
    required this.version,
    required this.versionUuid,
    required this.inputChipsSchema,
    this.billingType = 'free',
    this.pricingMode = 'per_skill',
  });

  final String skillUuid;
  final String code;
  final String name;
  final String iconUrl;
  final String kind; // agent / builtin
  final String executionMode; // synchronous_inline / asynchronous_floating
  final bool pinned;
  final int sortOrder;
  final String source; // default_inherit / manual_attach / temporary_attach
  final Map<String, dynamic> defaultParams;
  final String version;
  final String versionUuid;
  final List<dynamic> inputChipsSchema;
  final String billingType;
  final String pricingMode;

  bool get isPaid => billingType == 'paid';

  factory F03ChipItem.fromJson(Map<String, dynamic> j) {
    return F03ChipItem(
      skillUuid: (j['skill_uuid'] as String?) ?? '',
      code: (j['code'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      iconUrl: (j['icon_url'] as String?) ?? '',
      kind: (j['kind'] as String?) ?? 'agent',
      executionMode:
          (j['execution_mode'] as String?) ?? 'synchronous_inline',
      pinned: (j['pinned'] as bool?) ?? false,
      sortOrder: (j['sort_order'] as int?) ?? 0,
      source: (j['source'] as String?) ?? '',
      defaultParams: (j['default_params'] is Map)
          ? Map<String, dynamic>.from(j['default_params'] as Map)
          : <String, dynamic>{},
      version: (j['version'] as String?) ?? '',
      versionUuid: (j['version_uuid'] as String?) ?? '',
      inputChipsSchema: (j['input_chips_schema'] as List?) ?? const [],
      billingType: (j['billing_type'] as String?) ?? 'free',
      pricingMode: (j['pricing_mode'] as String?) ?? 'per_skill',
    );
  }
}

@immutable
class F03ToolRailItem {
  const F03ToolRailItem({required this.key, required this.icon});
  final String key;
  final String icon;
  factory F03ToolRailItem.fromJson(Map<String, dynamic> j) {
    return F03ToolRailItem(
      key: (j['key'] as String?) ?? '',
      icon: (j['icon'] as String?) ?? '',
    );
  }
}

@immutable
class F03SkillSquareItem {
  const F03SkillSquareItem({
    required this.skillUuid,
    required this.code,
    required this.name,
    required this.kind,
    required this.iconUrl,
    required this.isAttachedToAgent,
    required this.isTemporaryAttached,
    required this.installCount,
  });

  final String skillUuid;
  final String code;
  final String name;
  final String kind;
  final String iconUrl;
  final bool isAttachedToAgent;
  final bool isTemporaryAttached;
  final int installCount;

  factory F03SkillSquareItem.fromJson(Map<String, dynamic> j) {
    return F03SkillSquareItem(
      skillUuid: (j['skill_uuid'] as String?) ?? '',
      code: (j['code'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      kind: (j['kind'] as String?) ?? 'agent',
      iconUrl: (j['icon_url'] as String?) ?? '',
      isAttachedToAgent: (j['is_attached_to_agent'] as bool?) ?? false,
      isTemporaryAttached: (j['is_temporary_attached'] as bool?) ?? false,
      installCount: (j['install_count'] as int?) ?? 0,
    );
  }
}

@immutable
class F03SkillSquare {
  const F03SkillSquare({required this.items, required this.total});
  final List<F03SkillSquareItem> items;
  final int total;
  factory F03SkillSquare.fromJson(Map<String, dynamic> j) {
    return F03SkillSquare(
      items: ((j['items'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(F03SkillSquareItem.fromJson)
          .toList(),
      total: (j['total'] as int?) ?? 0,
    );
  }
}

@immutable
class F03Override {
  const F03Override({
    required this.overrideId,
    required this.accountId,
    required this.agentUuid,
    required this.skillUuid,
    required this.behavior,
    this.expiresAt,
  });
  final int overrideId;
  final int accountId;
  final String agentUuid;
  final String skillUuid;
  final String behavior;
  final DateTime? expiresAt;

  factory F03Override.fromJson(Map<String, dynamic> j) {
    DateTime? exp;
    if (j['expires_at'] is String) {
      exp = DateTime.tryParse(j['expires_at'] as String);
    }
    return F03Override(
      overrideId: (j['override_id'] as int?) ?? 0,
      accountId: (j['account_id'] as int?) ?? 0,
      agentUuid: (j['agent_uuid'] as String?) ?? '',
      skillUuid: (j['skill_uuid'] as String?) ?? '',
      behavior: (j['behavior'] as String?) ?? '',
      expiresAt: exp,
    );
  }
}
