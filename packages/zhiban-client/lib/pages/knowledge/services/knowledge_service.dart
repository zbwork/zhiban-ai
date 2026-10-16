import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/knowledge/knowledge_models.dart';

/// 知识库后端 API 封装(路由前缀 `/api/agent-bus/v1/knowledge-bases`)
class KnowledgeService {
  const KnowledgeService();

  static const String _basePath = '/knowledge-bases';

  /// 列某 Space 下所有 KB(共享 + 每 agent 一个)
  /// space: personal | org
  Future<List<KbItem>> listKB(String space) async {
    final response = await request.get(_basePath);
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    final parsed = items
        .whereType<Map>()
        .map((e) => KbItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    if (space == 'org') {
      return parsed.where((kb) => kb.spaceKind == 'tenant').toList();
    }
    return parsed
        .where((kb) => kb.spaceKind == 'personal' || kb.spaceKind.isEmpty)
        .toList();
  }

  Future<KbItem> createKB({
    required String name,
    required String space,
    String description = '',
  }) async {
    final isOrg = space == 'org';
    final response = await request.post(
      _basePath,
      data: {
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'space_kind': isOrg ? 'tenant' : 'personal',
        'visibility': isOrg ? 'tenant' : 'private',
      },
    );
    return KbItem.fromJson(responseAsMap(response));
  }

  Future<KbItem> renameKB({
    required String kbUuid,
    required String name,
  }) async {
    final response = await request.patch(
      '$_basePath/${Uri.encodeComponent(kbUuid)}',
      data: {'name': name},
    );
    return KbItem.fromJson(responseAsMap(response));
  }

  Future<void> deleteKB({required String kbUuid}) async {
    await request.delete('$_basePath/${Uri.encodeComponent(kbUuid)}');
  }

  Future<List<KbFolder>> listFolders({required String kbUuid}) async {
    final response = await request.get(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/folders/tree',
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => KbFolder.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<KbFolder> createFolder({
    required String kbUuid,
    required String name,
    String parentUuid = '',
  }) async {
    final response = await request.post(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/folders',
      data: {
        'name': name,
        if (parentUuid.isNotEmpty) 'parent_uuid': parentUuid,
      },
    );
    return KbFolder.fromJson(responseAsMap(response));
  }

  Future<KbFolder> renameFolder({
    required String kbUuid,
    required String folderUuid,
    required String name,
  }) async {
    final response = await request.patch(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/folders/${Uri.encodeComponent(folderUuid)}',
      data: {'name': name},
    );
    return KbFolder.fromJson(responseAsMap(response));
  }

  Future<void> deleteFolder({
    required String kbUuid,
    required String folderUuid,
  }) async {
    await request.delete(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/folders/${Uri.encodeComponent(folderUuid)}',
    );
  }

  /// 列 KB 下文档(可按 status / kbFolderId 过滤)
  Future<({List<KbDocument> items, int total})> listDocuments({
    required String kbUuid,
    String status = '',
    String kbFolderUuid = '',
    int page = 1,
    int pageSize = 50,
  }) async {
    final response = await request.get(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/documents',
      queryParameters: {
        if (status.isNotEmpty) 'status': status,
        if (kbFolderUuid.isNotEmpty) 'kb_folder_uuid': kbFolderUuid,
        'page': page,
        'page_size': pageSize,
      },
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return (
      items: items
          .whereType<Map>()
          .map((e) => KbDocument.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      total:
          (raw['total'] is num) ? (raw['total'] as num).toInt() : items.length,
    );
  }

  /// KB 内上传文档(物理走 drive,但 drive_folder_id=0,云盘看不见)
  Future<KbDocument> uploadDocument({
    required String kbUuid,
    required String filePath,
    required String fileName,
    String kbFolderUuid = '',
  }) async {
    final formFields = <String, dynamic>{};
    if (kbFolderUuid.isNotEmpty) {
      formFields['kb_folder_uuid'] = kbFolderUuid;
    }
    formFields['title'] = fileName;
    formFields['mime_type'] = _guessKnowledgeMime(fileName);
    // 走通用 upload 工具,但需要带额外 form field。直接构造 FormData 更直白。
    // uploadApiFile 不支持额外 field,这里用 dio 的 request.post + FormData。
    final response = await uploadApiFileWithFields(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/documents/upload',
      filePath: filePath,
      fileName: fileName,
      additionalFields: formFields,
    );
    return KbDocument.fromJson(responseAsMap(response));
  }

  String _guessKnowledgeMime(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';
    switch (ext) {
      case 'txt':
      case 'log':
        return 'text/plain';
      case 'md':
      case 'markdown':
        return 'text/markdown';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'tif':
      case 'tiff':
        return 'image/tiff';
      default:
        return 'application/octet-stream';
    }
  }

  /// 把云盘已有文件加入 KB(零拷贝引用)
  /// fileUuids 是 drive_files.uuid 列表
  Future<List<KbDocument>> linkFromDrive({
    required String kbUuid,
    required List<String> fileUuids,
    String kbFolderUuid = '',
  }) async {
    final out = <KbDocument>[];
    for (final fileUuid in fileUuids) {
      final response = await request.post(
        '$_basePath/${Uri.encodeComponent(kbUuid)}/documents/link-from-drive',
        data: {
          'drive_file_uuid': fileUuid,
          if (kbFolderUuid.isNotEmpty) 'kb_folder_uuid': kbFolderUuid,
        },
      );
      out.add(KbDocument.fromJson(responseAsMap(response)));
    }
    return out;
  }

  Future<void> deleteDocument({
    required String kbUuid,
    required String kbDocUuid,
  }) async {
    await request.delete(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/documents/${Uri.encodeComponent(kbDocUuid)}',
    );
  }

  Future<KbDocument> renameDocument({
    required String kbUuid,
    required String kbDocUuid,
    required String title,
  }) async {
    final response = await request.patch(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/documents/${Uri.encodeComponent(kbDocUuid)}',
      data: {'title': title},
    );
    return KbDocument.fromJson(responseAsMap(response));
  }

  Future<KbSearchResult> search({
    required String kbUuid,
    required String query,
    int topK = 5,
  }) async {
    final response = await request.post(
      '$_basePath/${Uri.encodeComponent(kbUuid)}/search',
      data: {
        'query': query,
        'top_k': topK
      },
    );
    return KbSearchResult.fromJson(responseAsMap(response));
  }
}
