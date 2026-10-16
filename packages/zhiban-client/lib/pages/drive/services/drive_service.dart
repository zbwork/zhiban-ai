import 'dart:io';

import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/drive/drive_models.dart';

/// 云盘后端 API 封装（drivev3）。
///
/// 路由前缀:`/api/agent-bus/v1/drive*`（baseUrl 已含 `/api/agent-bus/v1`，这里只拼 `/drive...`）。
/// 小文件默认走 Bus proxy 上传；大文件保留预签名直传：
/// presign-put → 直接 PUT 对象存储 → confirm / complete-multipart。
/// 契约见 docs/contracts/agent-bus-client-contract.md §4 + docs/features/F06-drive.md §3.2。
final _readOptions = Options(
  receiveTimeout: const Duration(seconds: 15),
  extra: const {'silent': true, 'pageRead': true},
);

class DriveService {
  const DriveService();

  static const String _base = '/drive';
  static const int _proxyUploadMaxBytes = 10 * 1024 * 1024;

  // ============================ 读 ============================

  /// 懒初始化 + 列 4 类 space。第一次进云盘页调一次,后端幂等。
  Future<DriveBootstrap> bootstrap() async {
    final response =
        await request.post('$_base:bootstrap', options: _readOptions);
    return DriveBootstrap.fromJson(responseAsMap(response));
  }

  /// 拉某 space 全部目录(扁平,前端自己拼树)。spaceUuid 为该 space 的真实 UUID。
  Future<List<DriveFolder>> folderTree(String spaceUuid) async {
    final response = await request.get(
      '$_base/spaces/${Uri.encodeComponent(spaceUuid)}/folders/tree',
      options: _readOptions,
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => DriveFolder.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 列某目录直接子目录 + 文件(分页)。
  Future<FolderChildren> listFolderChildren(
    String folderUuid, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final response = await request.get(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}/children',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return FolderChildren.fromJson(responseAsMap(response));
  }

  /// 列真实 space 根下的文件。用于「我的空间 / 云盘」和具体共享文件夹根视图。
  Future<List<DriveFile>> listRootFiles(String spaceUuid) async {
    final response = await request.get(
      '$_base/files',
      queryParameters: {'space_uuid': spaceUuid, 'root': '1', 'limit': 100},
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => DriveFile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // ============================ 目录 mutate ============================

  /// 创建 regular 子目录。parentUuid 为空表示挂在 space 根(允许)。
  Future<DriveFolder> createFolder({
    required String spaceUuid,
    required String name,
    String parentUuid = '',
  }) async {
    final response = await request.post(
      '$_base/folders',
      data: {
        'space_uuid': spaceUuid,
        if (parentUuid.isNotEmpty) 'parent_uuid': parentUuid,
        'name': name,
      },
    );
    return DriveFolder.fromJson(responseAsMap(response));
  }

  Future<DriveSpace> createSharedSpace({
    required String name,
    String description = '',
  }) async {
    final response = await request.post(
      '$_base/shared-spaces',
      data: {
        'name': name,
        if (description.trim().isNotEmpty) 'description': description.trim(),
      },
    );
    final raw = responseAsMap(response);
    final space =
        raw['space'] is Map ? Map<String, dynamic>.from(raw['space']) : raw;
    return DriveSpace.fromJson(space);
  }

  Future<DriveSpace> updateSharedSpace({
    required String spaceUuid,
    required String name,
    String? description,
  }) async {
    final response = await request.patch(
      '$_base/shared-spaces/${Uri.encodeComponent(spaceUuid)}',
      data: {
        'name': name,
        if (description != null) 'description': description.trim(),
      },
    );
    final raw = responseAsMap(response);
    final space =
        raw['space'] is Map ? Map<String, dynamic>.from(raw['space']) : raw;
    return DriveSpace.fromJson(space);
  }

  Future<void> deleteSharedSpace(String spaceUuid) async {
    await request.delete(
      '$_base/shared-spaces/${Uri.encodeComponent(spaceUuid)}',
    );
  }

  Future<DriveFolder> renameFolder({
    required String folderUuid,
    required String name,
  }) async {
    final response = await request.patch(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}',
      data: {'name': name},
    );
    return DriveFolder.fromJson(responseAsMap(response));
  }

  /// 同 space 内挪目录。newParentUuid 为空 = 移到 space 根。
  Future<DriveFolder> moveFolder({
    required String folderUuid,
    required String newParentUuid,
  }) async {
    final response = await request.post(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}/move',
      data: {'new_parent_uuid': newParentUuid},
    );
    return DriveFolder.fromJson(responseAsMap(response));
  }

  /// 软删目录。recursive=true 时级联子树(保留「删非空目录可成功」UX)。
  Future<void> deleteFolder(String folderUuid, {bool recursive = true}) async {
    await request.delete(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}',
      queryParameters: {if (recursive) 'recursive': 'true'},
    );
  }

  // ============================ 上传(预签名直传) ============================

  /// 上传文件到指定目录或真实 space 根。folderUuid 为空表示上传到 space 根。
  ///
  /// 流程:presign-put → 直传对象存储 → confirm(single) / complete-multipart(>=10MiB)。
  /// onProgress(sent, total) 可选,用于进度展示。
  Future<DriveFile> uploadFile({
    required String spaceUuid,
    String folderUuid = '',
    required String filePath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = File(filePath);
    final size = await file.length();
    final mime = _guessMime(fileName);

    if (size < _proxyUploadMaxBytes) {
      return _uploadFileViaBus(
        spaceUuid: spaceUuid,
        folderUuid: folderUuid,
        filePath: filePath,
        fileName: fileName,
        mime: mime,
        onProgress: onProgress,
      );
    }

    return _uploadFileDirect(
      spaceUuid: spaceUuid,
      folderUuid: folderUuid,
      file: file,
      size: size,
      fileName: fileName,
      mime: mime,
      onProgress: onProgress,
    );
  }

  Future<DriveFile> _uploadFileViaBus({
    required String spaceUuid,
    required String folderUuid,
    required String filePath,
    required String fileName,
    required String mime,
    void Function(int sent, int total)? onProgress,
  }) async {
    final fields = <String, dynamic>{
      'space_uuid': spaceUuid,
      if (folderUuid.isNotEmpty) 'folder_uuid': folderUuid,
      'file_name': fileName,
      'mime_type': mime,
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    };
    final resp = await request.post(
      '$_base/files:upload',
      data: FormData.fromMap(fields),
      onSendProgress: onProgress,
    );
    return _fileFromConfirm(resp);
  }

  Future<DriveFile> _uploadFileDirect({
    required String spaceUuid,
    required String folderUuid,
    required File file,
    required int size,
    required String fileName,
    required String mime,
    void Function(int sent, int total)? onProgress,
  }) async {
    // 1. presign-put
    final presignResp = await request.post(
      '$_base/files:presign-put',
      data: {
        'space_uuid': spaceUuid,
        if (folderUuid.isNotEmpty) 'folder_uuid': folderUuid,
        'file_name': fileName,
        'mime_type': mime,
        'size_bytes': size,
      },
    );
    final ticket = PresignTicket.fromJson(responseAsMap(presignResp));
    if (ticket.fileUuid.isEmpty) {
      throw StateError('presign-put 未返回 file_uuid');
    }

    if (ticket.isMultipart) {
      final parts = await _putMultipart(ticket, file, size, onProgress);
      final resp = await request.post(
        '$_base/files:complete-multipart',
        data: {'file_uuid': ticket.fileUuid, 'parts': parts},
      );
      return _fileFromConfirm(resp);
    } else {
      await _putSingle(ticket.presignUrl, file, size, mime, onProgress);
      final resp = await request.post(
        '$_base/files:confirm',
        data: {'file_uuid': ticket.fileUuid},
      );
      return _fileFromConfirm(resp);
    }
  }

  DriveFile _fileFromConfirm(dynamic resp) {
    final raw = responseAsMap(resp);
    // 后端返回 {file: FileResp}
    final fileMap =
        (raw['file'] is Map) ? Map<String, dynamic>.from(raw['file']) : raw;
    return DriveFile.fromJson(fileMap);
  }

  /// 单文件直传:PUT 整个 body 到 presign_url,必须带与 presign 声明一致的 Content-Type。
  Future<void> _putSingle(
    String presignUrl,
    File file,
    int size,
    String mime,
    void Function(int sent, int total)? onProgress,
  ) async {
    if (presignUrl.isEmpty) {
      throw StateError('single 模式缺少 presign_url');
    }
    final bytes = await file.readAsBytes();
    final resp = await _ossDio().put(
      presignUrl,
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: <String, dynamic>{
          HttpHeaders.contentTypeHeader: mime,
          HttpHeaders.contentLengthHeader: size,
        },
      ),
      onSendProgress: onProgress,
    );
    _ensureOk(resp, 'single PUT');
  }

  /// 分片直传:按 part_size 切片 PUT 到各 part_urls,收 ETag。URL 过期时续签一次重试。
  /// 返回 complete-multipart 用的 parts(part_number 升序 + etag)。
  Future<List<Map<String, dynamic>>> _putMultipart(
    PresignTicket ticket,
    File file,
    int size,
    void Function(int sent, int total)? onProgress,
  ) async {
    final partSize = ticket.partSize > 0 ? ticket.partSize : (10 << 20);
    var partUrls = List<String>.from(ticket.partUrls);
    final numParts = (size + partSize - 1) ~/ partSize;
    if (partUrls.length < numParts) {
      throw StateError(
          'presign 返回的 part_urls 数(${partUrls.length}) 少于所需分片数($numParts)');
    }

    final parts = <Map<String, dynamic>>[];
    final raf = await file.open();
    var sent = 0;
    try {
      var refreshed = false;
      for (var i = 0; i < numParts; i++) {
        final start = i * partSize;
        final len = (start + partSize <= size) ? partSize : (size - start);
        await raf.setPosition(start);
        final chunk = await raf.read(len);

        var etag = '';
        try {
          etag = await _putPart(partUrls[i], chunk);
        } on DioException {
          // URL 可能过期:续签全部 part 一次再重试当前分片。
          if (!refreshed) {
            refreshed = true;
            final fresh = await refreshPartUrls(ticket.fileUuid);
            if (fresh.partUrls.length >= numParts) {
              partUrls = fresh.partUrls;
            }
            etag = await _putPart(partUrls[i], chunk);
          } else {
            rethrow;
          }
        }
        parts.add({'part_number': i + 1, 'etag': etag});
        sent += len;
        onProgress?.call(sent, size);
      }
    } finally {
      await raf.close();
    }
    return parts;
  }

  Future<String> _putPart(String url, List<int> chunk) async {
    final resp = await _ossDio().put(
      url,
      data: Stream.fromIterable([chunk]),
      options: Options(
        headers: <String, dynamic>{
          HttpHeaders.contentLengthHeader: chunk.length,
        },
      ),
    );
    _ensureOk(resp, 'part PUT');
    final etag = resp.headers.value('etag') ?? resp.headers.value('ETag') ?? '';
    if (etag.isEmpty) {
      throw StateError('part PUT 未返回 ETag');
    }
    return etag;
  }

  /// 续签所有 part PUT URL(staging_key/upload_id 不变)。
  Future<RefreshedParts> refreshPartUrls(String fileUuid) async {
    final resp = await request.post(
      '$_base/files:refresh-part-urls',
      data: {'file_uuid': fileUuid},
    );
    return RefreshedParts.fromJson(responseAsMap(resp));
  }

  // ============================ 文件 read / mutate ============================

  /// 预览 / 下载签名 URL(JSON `{url, expires_at}`)。download=true 走 attachment。
  Future<PreviewUrl> previewUrl({
    required String fileUuid,
    bool download = false,
  }) async {
    final endpoint = download ? 'download' : 'preview';
    final response = await request.get(
      '$_base/files/${Uri.encodeComponent(fileUuid)}/$endpoint',
    );
    return PreviewUrl.fromJson(responseAsMap(response));
  }

  Future<void> deleteFile(String fileUuid) async {
    await request.delete('$_base/files/${Uri.encodeComponent(fileUuid)}');
  }

  Future<DriveFile> renameFile({
    required String fileUuid,
    required String name,
  }) async {
    final response = await request.patch(
      '$_base/files/${Uri.encodeComponent(fileUuid)}',
      data: {'name': name},
    );
    return DriveFile.fromJson(responseAsMap(response));
  }

  /// 同 space 内挪文件到另一个目录(只改 DB)。
  Future<DriveFile> moveFile({
    required String fileUuid,
    required String newFolderUuid,
  }) async {
    final response = await request.post(
      '$_base/files/${Uri.encodeComponent(fileUuid)}/move',
      data: {'new_folder_uuid': newFolderUuid},
    );
    return DriveFile.fromJson(responseAsMap(response));
  }

  // ============================ discover / chat ============================

  /// 侧栏「最近使用」。
  Future<List<DriveFile>> listRecentFiles({int limit = 50}) async {
    final response = await request.get(
      '$_base/files:recent',
      queryParameters: {'limit': limit},
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => DriveFile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 当前账号「我的收藏」。
  Future<List<DriveFavoriteItem>> listFavorites({int limit = 100}) async {
    final response = await request.get(
      '$_base/favorites',
      queryParameters: {'limit': limit},
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => DriveFavoriteItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 幂等收藏云盘文件或知识库文档。
  Future<void> addFavorite({
    required String targetKind,
    required String targetUuid,
    String kbUuid = '',
  }) async {
    await request.put(
      '$_base/favorites/${Uri.encodeComponent(targetKind)}/${Uri.encodeComponent(targetUuid)}',
      data: {
        if (kbUuid.isNotEmpty) 'kb_uuid': kbUuid
      },
    );
  }

  /// 幂等取消收藏。
  Future<void> removeFavorite({
    required String targetKind,
    required String targetUuid,
  }) async {
    await request.delete(
      '$_base/favorites/${Uri.encodeComponent(targetKind)}/${Uri.encodeComponent(targetUuid)}',
    );
  }

  /// 列聊天附件(导入弹框)。[conversationId] 为空跨全部会话最近 N 条。
  Future<List<ChatAttachment>> listChatAttachments({
    String? conversationId,
    int limit = 50,
  }) async {
    final response = await request.get(
      '$_base/files:chat-attachments',
      queryParameters: {
        if (conversationId != null && conversationId.isNotEmpty)
          'conversation_uuid': conversationId,
        'limit': limit,
      },
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => ChatAttachment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 把聊天附件 promote 到云盘指定目录。新后端按**单个** drive_file_uuid 导入,
  /// 多选时逐个循环。返回成功导入的文件列表;全部失败时抛首个异常。
  Future<List<DriveFile>> importFromChat({
    required String targetFolderUuid,
    required List<String> driveFileUuids,
  }) async {
    final out = <DriveFile>[];
    Object? firstErr;
    for (final fileUuid in driveFileUuids) {
      try {
        final resp = await request.post(
          '$_base/files:import-from-chat',
          data: {
            'drive_file_uuid': fileUuid,
            'target_folder_uuid': targetFolderUuid,
          },
        );
        out.add(_fileFromConfirm(resp));
      } catch (e) {
        firstErr ??= e;
      }
    }
    if (out.isEmpty && firstErr != null) {
      throw firstErr;
    }
    return out;
  }

  // ============================ 回收站(F06 基础设置 slice) ============================

  /// 列回收站。manager+ 才可见;后端鉴权。客户端**禁止**调用 admin 路径。
  Future<List<RecycleItem>> listRecycle({int limit = 100}) async {
    final response = await request.get(
      '$_base/recycle',
      queryParameters: {'limit': limit},
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => RecycleItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 为回收站里的图片文件获取预览 URL。使用 recycle uuid,不是 file uuid。
  Future<PreviewUrl> recyclePreviewUrl(String recycleUuid) async {
    final response = await request.get(
      '$_base/recycle/${Uri.encodeComponent(recycleUuid)}/preview',
      options: Options(extra: const {'silent': true}),
    );
    return PreviewUrl.fromJson(responseAsMap(response));
  }

  /// 恢复一行回收站条目(folder 或 file)。
  Future<void> restoreRecycle(String recycleUuid) async {
    await request.post(
      '$_base/recycle/${Uri.encodeComponent(recycleUuid)}/restore',
    );
  }

  /// 彻底删除一行回收站条目(对象存储 + DB)。
  Future<void> purgeRecycle(String recycleUuid) async {
    await request.delete(
      '$_base/recycle/${Uri.encodeComponent(recycleUuid)}/purge',
    );
  }

  // ============================ 共享文件夹协作者管理(F06 基础设置 slice) ============================

  /// 列 shared space 的所有成员(真实 owner 首项 + viewer/editor/manager)。
  Future<List<SpaceMember>> listSpaceMembers(String spaceUuid) async {
    final response = await request.get(
      '$_base/spaces/${Uri.encodeComponent(spaceUuid)}/members',
      options: Options(receiveTimeout: const Duration(seconds: 12)),
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => SpaceMember.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 添加成员。role ∈ viewer/editor/manager。
  Future<SpaceMember> addSpaceMember({
    required String spaceUuid,
    required String accountUuid,
    required String role,
  }) async {
    final response = await request.post(
      '$_base/spaces/${Uri.encodeComponent(spaceUuid)}/members',
      data: {'account_uuid': accountUuid, 'role': role},
    );
    return SpaceMember.fromJson(responseAsMap(response));
  }

  /// 更新成员角色。
  Future<SpaceMember> updateSpaceMember({
    required String spaceUuid,
    required String accountUuid,
    required String role,
  }) async {
    final response = await request.patch(
      '$_base/spaces/${Uri.encodeComponent(spaceUuid)}/members/${Uri.encodeComponent(accountUuid)}',
      data: {'role': role},
    );
    return SpaceMember.fromJson(responseAsMap(response));
  }

  /// 移除成员。
  Future<void> removeSpaceMember({
    required String spaceUuid,
    required String accountUuid,
  }) async {
    await request.delete(
      '$_base/spaces/${Uri.encodeComponent(spaceUuid)}/members/${Uri.encodeComponent(accountUuid)}',
    );
  }

  /// 列 shared space 下某 folder 的真实 owner + effective 协作者。
  Future<List<SpaceMember>> listFolderMembers(String folderUuid) async {
    final response = await request.get(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}/members',
      options: Options(receiveTimeout: const Duration(seconds: 12)),
    );
    final raw = responseAsMap(response);
    final items = (raw['items'] is List) ? raw['items'] as List : const [];
    return items
        .whereType<Map>()
        .map((e) => SpaceMember.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 添加 folder direct 协作者 grant。
  Future<SpaceMember> addFolderMember({
    required String folderUuid,
    required String accountUuid,
    required String role,
  }) async {
    final response = await request.post(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}/members',
      data: {'account_uuid': accountUuid, 'role': role},
    );
    return SpaceMember.fromJson(responseAsMap(response));
  }

  /// 更新 folder direct 协作者 grant;没有 direct grant 时后端会创建一条覆写 grant。
  Future<SpaceMember> updateFolderMember({
    required String folderUuid,
    required String accountUuid,
    required String role,
  }) async {
    final response = await request.patch(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}/members/${Uri.encodeComponent(accountUuid)}',
      data: {'role': role},
    );
    return SpaceMember.fromJson(responseAsMap(response));
  }

  /// 删除 folder direct grant;若上级仍授权,会恢复继承。
  Future<void> removeFolderMember({
    required String folderUuid,
    required String accountUuid,
  }) async {
    await request.delete(
      '$_base/folders/${Uri.encodeComponent(folderUuid)}/members/${Uri.encodeComponent(accountUuid)}',
    );
  }

  // ============================ helpers ============================

  /// OSS 直传必须脱离全局拦截器(鉴权头/响应解包会破坏签名校验与 body)。
  Dio _ossDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 600),
        receiveTimeout: const Duration(seconds: 60),
      ));

  void _ensureOk(Response resp, String label) {
    final code = resp.statusCode;
    if (code == null || code >= 300) {
      throw HttpException('$label 失败: HTTP $code');
    }
  }

  String _guessMime(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'svg':
        return 'image/svg+xml';
      case 'heic':
      case 'heif':
        return 'image/heic';
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
      case 'txt':
      case 'log':
        return 'text/plain';
      case 'md':
        return 'text/markdown';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      case 'xml':
        return 'application/xml';
      case 'zip':
        return 'application/zip';
      case 'rar':
        return 'application/x-rar-compressed';
      case '7z':
        return 'application/x-7z-compressed';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      default:
        return 'application/octet-stream';
    }
  }
}
