/// 知识库元数据
class KbItem {
  const KbItem({
    required this.uuid,
    required this.name,
    required this.scope,
    required this.status,
    this.spaceKind = '',
    this.visibility = '',
    this.totalDocuments = 0,
    this.canWrite = true,
    this.agentId = '',
    this.embeddingModel = '',
    this.avatarUrl = '',
  });

  final String uuid;
  final String name;

  /// shared | agent
  final String scope;
  final String spaceKind;
  final String visibility;
  final int totalDocuments;
  final bool canWrite;
  final String status;
  final String agentId;
  final String embeddingModel;

  /// scope=agent 时由后端从 agent 元数据填的头像 URL,空表示回退默认图标
  final String avatarUrl;

  bool get isShared => scope == 'shared' || spaceKind == 'tenant';
  bool get isAgent => scope == 'agent';
  String get totalDocumentsLabel => '$totalDocuments 个文档';

  factory KbItem.fromJson(Map<String, dynamic> json) {
    final spaceKind = (json['space_kind'] ?? '').toString();
    final rawScope = (json['scope'] ?? '').toString();
    final scope = rawScope.isNotEmpty
        ? rawScope
        : (spaceKind == 'tenant' ? 'shared' : spaceKind);
    return KbItem(
      uuid: (json['uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      scope: scope,
      spaceKind: spaceKind,
      visibility: (json['visibility'] ?? '').toString(),
      totalDocuments: (json['total_documents'] is num)
          ? (json['total_documents'] as num).toInt()
          : 0,
      canWrite: json['can_write'] is bool ? json['can_write'] as bool : true,
      status: (json['status'] ?? '').toString(),
      agentId: (json['agent_id'] ?? json['agentId'] ?? '').toString(),
      embeddingModel:
          (json['embedding_model'] ?? json['embeddingModel'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
    );
  }
}

/// KB 文档
class KbDocument {
  const KbDocument({
    required this.uuid,
    required this.kbUuid,
    required this.fileUuid,
    required this.fileName,
    required this.kbFolderUuid,
    required this.mimeType,
    required this.sizeBytes,
    required this.source,
    required this.status,
    required this.chunksCount,
    required this.createdAt,
    required this.updatedAt,
    this.ingestError = '',
    this.indexedAt,
  });

  final String uuid;
  final String kbUuid;
  final String kbFolderUuid;
  final String fileUuid;
  final String fileName;
  final String mimeType;
  final int sizeBytes;

  /// drive_link | kb_upload
  final String source;

  /// pending | parsing | indexing | ready | failed
  final String status;
  final String ingestError;
  final int chunksCount;
  final DateTime? indexedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get sourceLabel => source == 'drive_link' ? '来自云盘' : 'KB 内上传';

  String get statusLabel {
    switch (status) {
      case 'pending':
        return '待处理';
      case 'parsing':
        return '解析中';
      case 'indexing':
        return '索引中';
      case 'ready':
        return '可用';
      case 'failed':
        return '失败';
      default:
        return status;
    }
  }

  String get sizeDisplay {
    final n = sizeBytes;
    if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(1)}GB';
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)}MB';
    if (n >= 1 << 10) return '${(n / (1 << 10)).toStringAsFixed(1)}KB';
    return '${n}B';
  }

  factory KbDocument.fromJson(Map<String, dynamic> json) {
    DateTime? parseTsOpt(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    return KbDocument(
      uuid: (json['uuid'] ?? '').toString(),
      kbUuid: (json['kb_uuid'] ?? json['kbUuid'] ?? '').toString(),
      kbFolderUuid:
          (json['kb_folder_uuid'] ?? json['kbFolderUuid'] ?? '').toString(),
      fileUuid: (json['file_uuid'] ?? json['fileUuid'] ?? '').toString(),
      fileName: (json['file_name'] ?? json['fileName'] ?? json['title'] ?? '')
          .toString(),
      mimeType: (json['mime_type'] ?? json['mimeType'] ?? '').toString(),
      sizeBytes: (json['file_size'] is num)
          ? (json['file_size'] as num).toInt()
          : ((json['sizeBytes'] is num)
              ? (json['sizeBytes'] as num).toInt()
              : 0),
      source: (json['source'] ?? 'kb_upload').toString(),
      status: (json['status'] ?? 'pending').toString(),
      ingestError:
          (json['error_message'] ?? json['ingestError'] ?? '').toString(),
      chunksCount: (json['chunk_count'] is num)
          ? (json['chunk_count'] as num).toInt()
          : ((json['chunksCount'] is num)
              ? (json['chunksCount'] as num).toInt()
              : 0),
      indexedAt: parseTsOpt(json['indexed_at'] ?? json['indexedAt']),
      createdAt:
          parseTsOpt(json['created_at'] ?? json['createdAt']) ?? DateTime.now(),
      updatedAt: parseTsOpt(json['updated_at'] ?? json['updatedAt']) ??
          parseTsOpt(json['created_at'] ?? json['createdAt']) ??
          DateTime.now(),
    );
  }
}

class KbSearchChunk {
  const KbSearchChunk({
    required this.uuid,
    required this.chunkIndex,
    required this.content,
    required this.score,
    required this.source,
  });

  final String uuid;
  final int chunkIndex;
  final String content;
  final double score;
  final String source;

  factory KbSearchChunk.fromJson(Map<String, dynamic> json) {
    return KbSearchChunk(
      uuid: (json['uuid'] ?? '').toString(),
      chunkIndex: (json['chunk_index'] is num)
          ? (json['chunk_index'] as num).toInt()
          : 0,
      content: (json['content'] ?? '').toString(),
      score: (json['score'] is num) ? (json['score'] as num).toDouble() : 0,
      source: (json['source'] ?? '').toString(),
    );
  }
}

class KbSearchResult {
  const KbSearchResult({
    required this.kbUuid,
    required this.query,
    required this.chunks,
  });

  final String kbUuid;
  final String query;
  final List<KbSearchChunk> chunks;

  factory KbSearchResult.fromJson(Map<String, dynamic> json) {
    final rawChunks =
        (json['chunks'] is List) ? json['chunks'] as List : const [];
    return KbSearchResult(
      kbUuid: (json['kb_uuid'] ?? '').toString(),
      query: (json['query'] ?? '').toString(),
      chunks: rawChunks
          .whereType<Map>()
          .map((e) => KbSearchChunk.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// KB 内目录树节点(M2)。
class KbFolder {
  const KbFolder({
    required this.uuid,
    required this.kbUuid,
    required this.parentUuid,
    required this.name,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
  });

  final String uuid;
  final String kbUuid;
  final String parentUuid;
  final String name;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory KbFolder.fromJson(Map<String, dynamic> json) {
    DateTime parseTs(dynamic v) {
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    return KbFolder(
      uuid: (json['uuid'] ?? '').toString(),
      kbUuid: (json['kb_uuid'] ?? json['kbUuid'] ?? '').toString(),
      parentUuid: (json['parent_uuid'] ?? json['parentUuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      path: (json['path'] ?? '').toString(),
      createdAt: parseTs(json['created_at'] ?? json['createdAt']),
      updatedAt: parseTs(json['updated_at'] ?? json['updatedAt']),
    );
  }
}
