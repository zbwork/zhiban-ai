class SkillLatestVersion {
  const SkillLatestVersion({
    required this.uuid,
    required this.version,
    required this.changelog,
    required this.fileSize,
  });

  final String uuid;
  final String version;
  final String changelog;
  final int? fileSize;

  factory SkillLatestVersion.fromJson(Map<String, dynamic> json) {
    return SkillLatestVersion(
      uuid: json['uuid']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      fileSize: _readInt(json['fileSize'] ?? json['file_size']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'version': version,
      'changelog': changelog,
      if (fileSize != null) 'fileSize': fileSize,
    };
  }

  String get displayFileSize {
    final size = fileSize;
    if (size == null || size <= 0) return '--';
    const kb = 1024;
    const mb = 1024 * 1024;
    if (size >= mb) {
      return '${(size / mb).toStringAsFixed(size % mb == 0 ? 0 : 1)} MB';
    }
    if (size >= kb) {
      return '${(size / kb).toStringAsFixed(size % kb == 0 ? 0 : 1)} KB';
    }
    return '$size B';
  }

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }
}

class Skill {
  final String uuid;
  final String slug;
  final String displayName;
  final String description;
  final String source;
  final String scopeKind;
  final int? categoryId;
  final String status;
  final String installStatus;
  final bool isInstalled;
  final bool supportsInstallAction;
  final int downloadCount;
  final int versionCount;
  final SkillLatestVersion? latestVersion;
  final String? latestVersionUuid;
  final int? latestVersionFileSize;
  final String? version;
  // 自定义技能 (source == 'custom') 才会有这两个字段，标识它属于哪个 agent，
  // 客户端跳转 chat 时需要用到。
  final String? agentId;
  final String? agentName;
  // F03 广场列表已包含使用示例；只有旧版技能需要额外读取详情接口。
  final String usageExample;
  final List<SkillUsageExampleImage> usageExampleImages;
  // 技能图标 URL：列表与详情都返回；后端会保证非空（未上传时回落到默认扳手 data URI），
  // 前端可以直接 NetworkImage / Image.network 展示，自定义技能没有 icon 时为空字符串，
  // 由调用方决定 fallback。
  final String iconUrl;
  final String billingType;
  final String pricingMode;

  Skill({
    required this.uuid,
    required this.slug,
    required this.displayName,
    required this.description,
    required this.source,
    this.scopeKind = '',
    this.categoryId,
    required this.status,
    required this.installStatus,
    required this.isInstalled,
    this.supportsInstallAction = true,
    required this.downloadCount,
    required this.versionCount,
    this.latestVersion,
    this.latestVersionUuid,
    this.latestVersionFileSize,
    this.version,
    this.agentId,
    this.agentName,
    this.usageExample = '',
    this.usageExampleImages = const [],
    this.iconUrl = '',
    this.billingType = 'free',
    this.pricingMode = 'per_skill',
  });

  bool get isPaid => billingType == 'paid';
  bool get isPerOperation => pricingMode == 'per_operation';

  String get billingBadgeText {
    if (billingType != 'paid') return '免费';
    if (pricingMode == 'per_operation') return '按接口计费';
    return '付费';
  }

  String get billingHintText {
    if (billingType != 'paid') return '';
    if (pricingMode == 'per_operation') {
      return '该技能按不同接口消耗积分，是否继续？';
    }
    return '使用该技能会消耗积分，是否继续？';
  }

  Skill copyWith({
    String? uuid,
    String? slug,
    String? displayName,
    String? description,
    String? source,
    String? scopeKind,
    int? categoryId,
    String? status,
    String? installStatus,
    bool? isInstalled,
    bool? supportsInstallAction,
    int? downloadCount,
    int? versionCount,
    SkillLatestVersion? latestVersion,
    String? latestVersionUuid,
    int? latestVersionFileSize,
    String? version,
  }) {
    return Skill(
      uuid: uuid ?? this.uuid,
      slug: slug ?? this.slug,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      source: source ?? this.source,
      scopeKind: scopeKind ?? this.scopeKind,
      categoryId: categoryId ?? this.categoryId,
      status: status ?? this.status,
      installStatus: installStatus ?? this.installStatus,
      isInstalled: isInstalled ?? this.isInstalled,
      supportsInstallAction:
          supportsInstallAction ?? this.supportsInstallAction,
      downloadCount: downloadCount ?? this.downloadCount,
      versionCount: versionCount ?? this.versionCount,
      latestVersion: latestVersion ?? this.latestVersion,
      latestVersionUuid: latestVersionUuid ?? this.latestVersionUuid,
      latestVersionFileSize:
          latestVersionFileSize ?? this.latestVersionFileSize,
      version: version ?? this.version,
      agentId: agentId,
      agentName: agentName,
      usageExample: usageExample,
      usageExampleImages: usageExampleImages,
      iconUrl: iconUrl,
      billingType: billingType,
      pricingMode: pricingMode,
    );
  }

  factory Skill.fromJson(Map<String, dynamic> json) {
    final isF03Shape =
        json.containsKey('skill_uuid') || json.containsKey('code');
    final attached = json['is_attached_to_agent'] is bool
        ? json['is_attached_to_agent'] as bool
        : false;
    final temporaryAttached = json['is_temporary_attached'] is bool
        ? json['is_temporary_attached'] as bool
        : false;
    final installed = json['isInstalled'] is bool
        ? json['isInstalled'] as bool
        : json['is_installed'] is bool
            ? json['is_installed'] as bool
            : attached || temporaryAttached;
    final installStatus = json['installStatus']?.toString() ??
        json['install_status']?.toString() ??
        (installed ? 'installed' : '');

    String? versionStr;
    int? fileSize;
    final latestVersionValue = json['latestVersion'] ?? json['latest_version'];
    if (latestVersionValue is Map<String, dynamic>) {
      versionStr = latestVersionValue['version']?.toString();
      fileSize = _readInt(
        latestVersionValue['fileSize'] ?? latestVersionValue['file_size'],
      );
    } else if (latestVersionValue != null) {
      versionStr = latestVersionValue.toString();
    }

    return Skill(
      uuid: json['uuid']?.toString() ?? json['skill_uuid']?.toString() ?? '',
      slug: json['slug']?.toString() ?? json['code']?.toString() ?? '',
      displayName: json['displayName']?.toString() ??
          json['display_name']?.toString() ??
          json['name']?.toString() ??
          json['code']?.toString() ??
          json['slug']?.toString() ??
          '',
      description: json['description']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      scopeKind: json['scope_kind']?.toString() ?? '',
      categoryId: _readInt(json['category_id']),
      status: json['status']?.toString() ?? (isF03Shape ? 'active' : ''),
      installStatus: installStatus,
      isInstalled: installed,
      supportsInstallAction: json['supportsInstallAction'] is bool
          ? json['supportsInstallAction'] as bool
          : json['supports_install_action'] is bool
              ? json['supports_install_action'] as bool
              : !isF03Shape,
      downloadCount: _readInt(
            json['downloadCount'] ??
                json['download_count'] ??
                json['downloads'] ??
                json['install_count'],
          ) ??
          0,
      versionCount:
          _readInt(json['versionCount'] ?? json['version_count']) ?? 0,
      latestVersion: latestVersionValue is Map<String, dynamic>
          ? SkillLatestVersion.fromJson(latestVersionValue)
          : null,
      latestVersionUuid: latestVersionValue is Map<String, dynamic>
          ? latestVersionValue['uuid']?.toString()
          : json['latest_version_uuid']?.toString(),
      latestVersionFileSize: fileSize ??
          _readInt(
            json['latestVersionFileSize'] ?? json['latest_version_file_size'],
          ),
      version: versionStr,
      agentId: json['agentId']?.toString() ?? json['agent_id']?.toString(),
      agentName:
          json['agentName']?.toString() ?? json['agent_name']?.toString(),
      usageExample: json['usageExample']?.toString() ??
          json['usage_example']?.toString() ??
          '',
      usageExampleImages: _readUsageExampleImages(
        json['usageExampleImages'] ?? json['usage_example_images'],
      ),
      iconUrl:
          json['iconUrl']?.toString() ?? json['icon_url']?.toString() ?? '',
      billingType:
          _billingStr(json['billingType'] ?? json['billing_type'], 'free'),
      pricingMode:
          _billingStr(json['pricingMode'] ?? json['pricing_mode'], 'per_skill'),
    );
  }

  static String _billingStr(dynamic value, String fallback) {
    if (value is String && value.isNotEmpty) return value;
    return fallback;
  }

  static List<SkillUsageExampleImage> _readUsageExampleImages(dynamic raw) {
    if (raw is! List) return const <SkillUsageExampleImage>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SkillUsageExampleImage.fromJson)
        .where((it) => it.url.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'slug': slug,
      'display_name': displayName,
      'description': description,
      'source': source,
      'scope_kind': scopeKind,
      if (categoryId != null) 'category_id': categoryId,
      'status': status,
      'installStatus': installStatus,
      'isInstalled': isInstalled,
      'supports_install_action': supportsInstallAction,
      'download_count': downloadCount,
      'version_count': versionCount,
      if (latestVersion != null) 'latestVersion': latestVersion!.toJson(),
      if (latestVersionUuid != null) 'latest_version_uuid': latestVersionUuid,
      if (latestVersionFileSize != null)
        'latest_version_file_size': latestVersionFileSize,
    };
  }

  String get displayTitle => displayName.isNotEmpty ? displayName : slug;
  String get displayVersion => latestVersion?.version ?? version ?? '--';
  String get statusLabel => status.isNotEmpty ? status : '--';
  String get installStatusLabel => installStatus.isNotEmpty
      ? installStatus
      : (isInstalled ? 'installed' : '--');
  String get installationLabel => isInstalled ? '已安装' : '未安装';
  String get sourceLabel {
    switch (source) {
      case 'internal':
      case 'official':
        return '公司内部';
      case 'open_source':
      case 'community':
        return '开源网站';
      default:
        return '开源网站';
    }
  }

  String get displayFileSize {
    final latest = latestVersion;
    if (latest != null) return latest.displayFileSize;
    final size = latestVersionFileSize;
    if (size == null || size <= 0) return '--';
    const kb = 1024;
    const mb = 1024 * 1024;
    if (size >= mb) {
      return '${(size / mb).toStringAsFixed(size % mb == 0 ? 0 : 1)} MB';
    }
    if (size >= kb) {
      return '${(size / kb).toStringAsFixed(size % kb == 0 ? 0 : 1)} KB';
    }
    return '$size B';
  }

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }
}

class InstalledSkill {
  const InstalledSkill({
    required this.slug,
    required this.name,
    required this.status,
    required this.version,
    required this.source,
    this.installedAt,
  });

  final String slug;
  final String name;
  final String status;
  final String version;
  final String source;
  final DateTime? installedAt;

  factory InstalledSkill.fromJson(Map<String, dynamic> json) {
    return InstalledSkill(
      slug: (json['slug'] ?? '').toString(),
      name: (json['name'] ?? json['displayName'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      installedAt: _readDateTime(json['installedAt'] ?? json['installed_at']),
    );
  }

  String get displayTitle => name.isNotEmpty ? name : slug;
  String get statusLabel => status.isNotEmpty ? status : '--';
  String? get installedAtLabel {
    final value = installedAt;
    if (value == null) return null;
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}

/// 技能广场分组：基础技能 / 专业技能 / ... / 自定义技能。
///
/// 自定义分组的 [groupKey] == 'custom'，业务侧据此区分渲染逻辑（虚线
/// 预留卡 + 「添加自定义技能」按钮），其它分组直接列出 [skills]。
class SkillGroup {
  const SkillGroup({
    required this.groupKey,
    required this.groupName,
    required this.skills,
  });

  final String groupKey;
  final String groupName;
  final List<Skill> skills;

  bool get isCustom => groupKey == 'custom';

  factory SkillGroup.fromJson(Map<String, dynamic> json) {
    final raw = json['skills'];
    final skills = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(Skill.fromJson)
            .toList(growable: false)
        : const <Skill>[];
    return SkillGroup(
      groupKey: (json['groupKey'] ?? json['group_key'] ?? '').toString(),
      groupName: (json['groupName'] ?? json['group_name'] ?? '').toString(),
      skills: skills,
    );
  }
}

class SkillCategory {
  const SkillCategory({
    required this.id,
    required this.code,
    required this.name,
    required this.sortOrder,
  });

  final int id;
  final String code;
  final String name;
  final int sortOrder;

  factory SkillCategory.fromJson(Map<String, dynamic> json) {
    return SkillCategory(
      id: Skill._readInt(json['id']) ?? 0,
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      sortOrder: Skill._readInt(json['sort_order']) ?? 0,
    );
  }
}

/// 「使用示例」附带的图片，URL 由后端直接给出，可直接展示。
class SkillUsageExampleImage {
  const SkillUsageExampleImage({
    required this.uuid,
    required this.url,
    required this.fileName,
  });

  final String uuid;
  final String url;
  final String fileName;

  factory SkillUsageExampleImage.fromJson(Map<String, dynamic> json) {
    return SkillUsageExampleImage(
      uuid: json['uuid']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      fileName:
          json['fileName']?.toString() ?? json['file_name']?.toString() ?? '',
    );
  }
}
