/// 云盘 Space。新后端 bootstrap 返回 4 类：personal / tenant / department / shared。
/// F06 cutover:客户端 UI 把 tenant + department + shared **过渡聚合**到
/// 「共享空间 / 云盘」分类;具体 shared space 作为“协作文件夹”呈现。
/// 长期重设计(2-bucket schema + 部门作为 ACL subject)见
/// docs/plans/drive-two-bucket-rethink.md;本期不动 schema/DTO/ACL。
class DriveSpace {
  const DriveSpace({
    required this.uuid,
    required this.kind,
    required this.name,
    required this.status,
    this.usedBytes = 0,
    this.description = '',
  });

  /// personal | tenant | department | shared
  final String kind;
  final String uuid;
  final String name;
  final String description;
  final String status;
  final int usedBytes;

  bool get isPersonal => kind == 'personal';
  bool get isOrg => !isPersonal;

  /// UI 文案：优先后端 name；个人空间兜底「我的空间」。
  String get displayName {
    if (name.isNotEmpty) return name;
    if (kind == 'personal') return '我的空间';
    if (kind == 'tenant') return '共享空间';
    return kind;
  }

  factory DriveSpace.fromJson(Map<String, dynamic> json) {
    return DriveSpace(
      uuid: (json['uuid'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      usedBytes:
          (json['used_bytes'] is num) ? (json['used_bytes'] as num).toInt() : 0,
    );
  }
}

/// POST /drive:bootstrap 响应（业务体形如 `{spaces:{personal,tenant,departments[],shared[]}}`）。
class DriveBootstrap {
  const DriveBootstrap({
    this.personal,
    this.tenant,
    this.departments = const [],
    this.shared = const [],
  });

  final DriveSpace? personal;
  final DriveSpace? tenant;
  final List<DriveSpace> departments;
  final List<DriveSpace> shared;

  /// 「共享空间 / 云盘」分类的过渡聚合(F06 cutover):tenant + 各部门 + 各共享空间。
  /// 标识符保留 `orgSpaces`,但 UI 文案统一显示「共享空间」。
  /// 长期 2-bucket 重设计见 docs/plans/drive-two-bucket-rethink.md。
  List<DriveSpace> get orgSpaces => [
        if (tenant != null) tenant!,
        ...departments,
        ...shared,
      ];

  /// personal + 组织各空间（全部需要加载目录树的空间）。
  List<DriveSpace> get allSpaces => [
        if (personal != null) personal!,
        ...orgSpaces,
      ];

  static DriveSpace? _space(dynamic v) =>
      v is Map ? DriveSpace.fromJson(Map<String, dynamic>.from(v)) : null;

  static List<DriveSpace> _spaceList(dynamic v) => (v is List)
      ? v
          .whereType<Map>()
          .map((e) => DriveSpace.fromJson(Map<String, dynamic>.from(e)))
          .toList()
      : const <DriveSpace>[];

  factory DriveBootstrap.fromJson(Map<String, dynamic> json) {
    // 兼容：业务体可能是 {spaces:{...}} 或直接 {...}。
    final spaces = (json['spaces'] is Map)
        ? Map<String, dynamic>.from(json['spaces'])
        : json;
    return DriveBootstrap(
      personal: _space(spaces['personal']),
      tenant: _space(spaces['tenant']),
      departments: _spaceList(spaces['departments']),
      shared: _spaceList(spaces['shared']),
    );
  }
}

/// 云盘目录节点
class DriveFolder {
  const DriveFolder({
    required this.uuid,
    required this.name,
    required this.kind,
    required this.parentId,
    required this.path,
    required this.isSystem,
    this.agentId = '',
    this.sort = 0,
    this.avatarUrl = '',
  });

  /// 目录 UUID(对外标识)
  final String uuid;
  final String name;

  /// regular | de_root | de_agent | de_outputs
  final String kind;

  /// 父目录 UUID(后端 parent_uuid),空字符串表示 space 根
  final String parentId;
  final String path;
  final bool isSystem;

  /// kind=de_agent / de_outputs 时填,关联的 agent_id
  final String agentId;
  final int sort;

  /// 后端不返目录头像 URL;保留字段供未来按 agentId 客户端解析,默认空 → 用默认图标。
  final String avatarUrl;

  bool get isAgentRoot => kind == 'de_agent';
  bool get isResultsFolder => kind == 'de_outputs';
  bool get isDeRoot => kind == 'de_root';
  bool get isRegular => kind == 'regular';

  factory DriveFolder.fromJson(Map<String, dynamic> json) {
    return DriveFolder(
      uuid: (json['uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      kind: (json['kind'] ?? 'regular').toString(),
      parentId: (json['parent_uuid'] ?? '').toString(),
      path: (json['path'] ?? '').toString(),
      isSystem: json['is_system'] == true,
      agentId: (json['agent_id'] ?? '').toString(),
      sort: (json['sort'] is num) ? (json['sort'] as num).toInt() : 0,
      avatarUrl: (json['avatar_url'] ?? '').toString(),
    );
  }
}

/// 云盘文件项
class DriveFile {
  const DriveFile({
    required this.uuid,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.source,
    required this.driveFolderUuid,
    required this.createdAt,
    required this.updatedAt,
    this.spaceUuid = '',
    this.ownerAccountUuid = '',
    this.ownerDisplayName = '',
    this.ownerAvatarUrl = '',
  });

  final String uuid;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final String source;
  final String spaceUuid;
  final String driveFolderUuid;
  final String ownerAccountUuid;
  final String ownerDisplayName;
  final String ownerAvatarUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get sizeDisplay {
    final n = sizeBytes;
    if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(1)}GB';
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)}MB';
    if (n >= 1 << 10) return '${(n / (1 << 10)).toStringAsFixed(1)}KB';
    return '${n}B';
  }

  /// 列表副标题使用的可读文件类型。优先扩展名，避免把
  /// application/vnd.openxmlformats... 之类的协议值直接展示给用户。
  String get typeDisplay {
    final normalizedName = name.trim();
    final separator = normalizedName.lastIndexOf(RegExp(r'[/\\]'));
    final dot = normalizedName.lastIndexOf('.');
    if (dot > separator && dot < normalizedName.length - 1) {
      return normalizedName.substring(dot + 1).toUpperCase();
    }

    final mime = mimeType.trim().toLowerCase().split(';').first;
    const exact = <String, String>{
      'application/pdf': 'PDF',
      'application/msword': 'DOC',
      'application/vnd.ms-excel': 'XLS',
      'application/vnd.ms-powerpoint': 'PPT',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
          'DOCX',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
          'XLSX',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation':
          'PPTX',
      'application/json': 'JSON',
      'application/zip': 'ZIP',
      'application/x-rar-compressed': 'RAR',
      'application/x-7z-compressed': '7Z',
      'text/plain': 'TXT',
      'text/csv': 'CSV',
      'text/markdown': 'MD',
    };
    final known = exact[mime];
    if (known != null) return known;

    for (final prefix in const ['image/', 'audio/', 'video/']) {
      if (mime.startsWith(prefix) && mime.length > prefix.length) {
        return mime.substring(prefix.length).toUpperCase();
      }
    }
    return '文件';
  }

  static DateTime _parseTs(dynamic v) {
    if (v == null) return DateTime.now();
    try {
      return DateTime.parse(v.toString());
    } catch (_) {
      return DateTime.now();
    }
  }

  factory DriveFile.fromJson(Map<String, dynamic> json) {
    return DriveFile(
      uuid: (json['uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      sizeBytes:
          (json['size_bytes'] is num) ? (json['size_bytes'] as num).toInt() : 0,
      source: (json['source'] ?? '').toString(),
      spaceUuid: (json['space_uuid'] ?? '').toString(),
      driveFolderUuid: (json['folder_uuid'] ?? '').toString(),
      ownerAccountUuid: (json['owner_account_uuid'] ?? '').toString(),
      ownerDisplayName: (json['owner_display_name'] ?? '').toString(),
      ownerAvatarUrl: (json['owner_avatar_url'] ?? '').toString(),
      createdAt: _parseTs(json['created_at']),
      updatedAt: _parseTs(json['updated_at']),
    );
  }
}

/// 「我的收藏」统一投影。target_kind 区分云盘文件与知识库文档。
class DriveFavoriteItem {
  const DriveFavoriteItem({
    required this.favoriteUuid,
    required this.targetKind,
    required this.targetUuid,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.favoritedAt,
    this.kbUuid = '',
    this.spaceUuid = '',
    this.folderUuid = '',
  });

  final String favoriteUuid;
  final String targetKind;
  final String targetUuid;
  final String kbUuid;
  final String spaceUuid;
  final String folderUuid;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime favoritedAt;

  bool get isDriveFile => targetKind == 'drive_file';
  bool get isKbDocument => targetKind == 'kb_document';
  String get sourceLabel => isKbDocument ? '知识库' : '云盘';

  String get sizeDisplay {
    final n = sizeBytes;
    if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(1)}GB';
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)}MB';
    if (n >= 1 << 10) return '${(n / (1 << 10)).toStringAsFixed(1)}KB';
    return '${n}B';
  }

  factory DriveFavoriteItem.fromJson(Map<String, dynamic> json) {
    DateTime parseTs(dynamic value) {
      try {
        return DateTime.parse(value.toString());
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    return DriveFavoriteItem(
      favoriteUuid: (json['favorite_uuid'] ?? '').toString(),
      targetKind: (json['target_kind'] ?? '').toString(),
      targetUuid: (json['target_uuid'] ?? '').toString(),
      kbUuid: (json['kb_uuid'] ?? '').toString(),
      spaceUuid: (json['space_uuid'] ?? '').toString(),
      folderUuid: (json['folder_uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      sizeBytes:
          (json['size_bytes'] is num) ? (json['size_bytes'] as num).toInt() : 0,
      status: (json['status'] ?? '').toString(),
      createdAt: parseTs(json['created_at']),
      updatedAt: parseTs(json['updated_at']),
      favoritedAt: parseTs(json['favorited_at']),
    );
  }
}

/// 目录子项混合(folders + files + total)
class FolderChildren {
  const FolderChildren({
    required this.folders,
    required this.files,
    required this.total,
  });

  final List<DriveFolder> folders;
  final List<DriveFile> files;
  final int total;

  factory FolderChildren.fromJson(Map<String, dynamic> json) {
    final folders = (json['folders'] is List)
        ? (json['folders'] as List)
            .whereType<Map>()
            .map((e) => DriveFolder.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <DriveFolder>[];
    final files = (json['files'] is List)
        ? (json['files'] as List)
            .whereType<Map>()
            .map((e) => DriveFile.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <DriveFile>[];
    return FolderChildren(
      folders: folders,
      files: files,
      total: (json['total'] is num) ? (json['total'] as num).toInt() : 0,
    );
  }
}

/// 聊天附件项 —— 给「导入聊天文件」弹框展示用。
/// 新后端按单个 drive_file_uuid 导入,所以选择 key 是 [driveFileUuid]。
class ChatAttachment {
  const ChatAttachment({
    required this.driveFileUuid,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.role,
    required this.conversationId,
    required this.conversationName,
    required this.agentName,
    required this.createdAt,
  });

  /// drive_files.uuid (scope=chat)；ImportFromChat 接口按这个单个导入。
  final String driveFileUuid;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  // user_input | assistant_output
  final String role;
  final String conversationId;
  final String conversationName;
  final String agentName;
  final DateTime createdAt;

  String get sizeDisplay {
    final n = sizeBytes;
    if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(1)}GB';
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)}MB';
    if (n >= 1 << 10) return '${(n / (1 << 10)).toStringAsFixed(1)}KB';
    return '${n}B';
  }

  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    DateTime parseTs(dynamic v) {
      if (v == null) return DateTime.now();
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return DateTime.now();
      }
    }

    return ChatAttachment(
      driveFileUuid: (json['drive_file_uuid'] ?? '').toString(),
      fileName: (json['name'] ?? json['file_name'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      sizeBytes:
          (json['size_bytes'] is num) ? (json['size_bytes'] as num).toInt() : 0,
      role: (json['role'] ?? '').toString(),
      conversationId: (json['conversation_uuid'] ?? '').toString(),
      conversationName: (json['conversation_name'] ?? '').toString(),
      agentName: (json['agent_name'] ?? '').toString(),
      createdAt: parseTs(json['created_at']),
    );
  }
}

/// 预览 / 下载签名 URL（后端返回 JSON `{url, expires_at}`，非 302）。
class PreviewUrl {
  const PreviewUrl({required this.url, this.expiresAt});
  final String url;
  final DateTime? expiresAt;

  factory PreviewUrl.fromJson(Map<String, dynamic> json) {
    DateTime? exp;
    final raw = json['expires_at'];
    if (raw != null) {
      try {
        exp = DateTime.parse(raw.toString());
      } catch (_) {
        exp = null;
      }
    }
    return PreviewUrl(url: (json['url'] ?? '').toString(), expiresAt: exp);
  }
}

/// presign-put 返回的上传票据（客户端只拿到 file_uuid + presign_url/part_urls + part_size，
/// 不含 staging_key/final_key/upload_id）。
class PresignTicket {
  const PresignTicket({
    required this.mode,
    required this.fileUuid,
    this.presignUrl = '',
    this.partUrls = const [],
    this.partSize = 0,
    this.expiresIn = 0,
  });

  /// single | multipart
  final String mode;
  final String fileUuid;
  final String presignUrl;
  final List<String> partUrls;
  final int partSize;
  final int expiresIn;

  bool get isMultipart => mode == 'multipart';

  factory PresignTicket.fromJson(Map<String, dynamic> json) {
    final ticket = (json['ticket'] is Map)
        ? Map<String, dynamic>.from(json['ticket'])
        : <String, dynamic>{};
    final partUrls = (ticket['part_urls'] is List)
        ? (ticket['part_urls'] as List).map((e) => e.toString()).toList()
        : <String>[];
    return PresignTicket(
      mode: (json['mode'] ?? 'single').toString(),
      fileUuid: (ticket['file_uuid'] ?? '').toString(),
      presignUrl: (ticket['presign_url'] ?? '').toString(),
      partUrls: partUrls,
      partSize: (ticket['part_size'] is num)
          ? (ticket['part_size'] as num).toInt()
          : 0,
      expiresIn: (ticket['expires_in'] is num)
          ? (ticket['expires_in'] as num).toInt()
          : 0,
    );
  }
}

/// refresh-part-urls 响应。
class RefreshedParts {
  const RefreshedParts({
    required this.partUrls,
    required this.partSize,
    required this.expiresIn,
  });

  final List<String> partUrls;
  final int partSize;
  final int expiresIn;

  factory RefreshedParts.fromJson(Map<String, dynamic> json) {
    final partUrls = (json['part_urls'] is List)
        ? (json['part_urls'] as List).map((e) => e.toString()).toList()
        : <String>[];
    return RefreshedParts(
      partUrls: partUrls,
      partSize:
          (json['part_size'] is num) ? (json['part_size'] as num).toInt() : 0,
      expiresIn:
          (json['expires_in'] is num) ? (json['expires_in'] as num).toInt() : 0,
    );
  }
}

/// 回收站行项目(F06 基础设置 slice)。后端契约见 docs/contracts/agent-bus-client-contract.md §4.2。
class RecycleItem {
  const RecycleItem({
    required this.uuid,
    required this.targetKind,
    this.targetUuid = '',
    required this.spaceUuid,
    required this.name,
    required this.deletedAtLogical,
    required this.expiresAt,
    required this.bytesToReclaim,
    this.locationPath = '',
    this.mimeType = '',
    this.previewUrl = '',
    this.deletedByAccountUuid = '',
    this.deletedByDisplayName = '',
    this.deletedByAvatarUrl = '',
  });

  final String uuid;

  /// 'folder' | 'file'
  final String targetKind;
  final String targetUuid;
  final String spaceUuid;
  final String name;
  final String locationPath;
  final String mimeType;
  final String previewUrl;
  final String deletedByAccountUuid;
  final String deletedByDisplayName;
  final String deletedByAvatarUrl;
  final DateTime deletedAtLogical;
  final DateTime expiresAt;
  final int bytesToReclaim;

  bool get isFile => targetKind == 'file';
  bool get isFolder => targetKind == 'folder';

  String get sizeDisplay {
    final n = bytesToReclaim;
    if (n <= 0) return '';
    if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(1)}GB';
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)}MB';
    if (n >= 1 << 10) return '${(n / (1 << 10)).toStringAsFixed(1)}KB';
    return '${n}B';
  }

  static DateTime _ts(dynamic v) {
    if (v == null) return DateTime.now();
    try {
      return DateTime.parse(v.toString());
    } catch (_) {
      return DateTime.now();
    }
  }

  factory RecycleItem.fromJson(Map<String, dynamic> json) {
    final targetUuid = (json['target_uuid'] ??
            json['target_file_uuid'] ??
            json['file_uuid'] ??
            '')
        .toString();
    final previewUrl =
        (json['preview_url'] ?? json['previewUrl'] ?? json['url'] ?? '')
            .toString();
    final locationPath =
        (json['location_path'] ?? json['locationPath'] ?? '').toString();
    return RecycleItem(
      uuid: (json['uuid'] ?? '').toString(),
      targetKind: (json['target_kind'] ?? '').toString(),
      targetUuid: targetUuid,
      spaceUuid: (json['space_uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      locationPath: locationPath,
      mimeType: (json['mime_type'] ?? '').toString(),
      previewUrl: previewUrl,
      deletedByAccountUuid: (json['deleted_by_account_uuid'] ?? '').toString(),
      deletedByDisplayName: (json['deleted_by_display_name'] ?? '').toString(),
      deletedByAvatarUrl: (json['deleted_by_avatar_url'] ?? '').toString(),
      deletedAtLogical: _ts(json['deleted_at_logical']),
      expiresAt: _ts(json['expires_at']),
      bytesToReclaim: (json['bytes_to_reclaim'] is num)
          ? (json['bytes_to_reclaim'] as num).toInt()
          : 0,
    );
  }
}

/// 共享文件夹协作者(F06 基础设置 slice)。后端契约见 docs/contracts/agent-bus-client-contract.md §4.2。
/// 后端 MemberResp 只返 `{account_id, account_uuid, role}`,不带名字/头像;
/// 显示名由客户端走 ContactsService 用 [accountUuid] 解析。
class SpaceMember {
  const SpaceMember({
    required this.accountUuid,
    required this.role,
  });

  final String accountUuid;

  /// GET: 'owner' | 'viewer' | 'editor' | 'manager'.
  /// 写接口仍只接受 viewer/editor/manager。
  final String role;

  factory SpaceMember.fromJson(Map<String, dynamic> json) {
    return SpaceMember(
      accountUuid: (json['account_uuid'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
    );
  }
}
