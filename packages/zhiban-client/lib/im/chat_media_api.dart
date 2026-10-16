import 'package:zhiban_client/network/network.dart';

/// P2.2c 聊天文件消息会话级媒体引用客户端(`POST /chat/media`)。
///
/// 安全(见 docs/plans/06):WuKong payload 只放 `/chat/media/{ref}/preview|download`
/// 稳定 Bus URL;**不**下发 S3 signed / :5001 / 原始私有 drive URL。preview/download
/// 由 Bus 按 room 成员鉴权后现签短 TTL → 302。
class ChatMediaApi {
  /// 为「发到某会话的一个 drive 文件(本地上传产物 或 云盘文件)」建 ref。
  /// 后端校验:caller 是会话活跃成员 + 对源文件有权(自己 chat 上传 或 云盘 viewer+)。
  Future<ChatMediaRef> createRef({
    required String conversationUuid,
    required String driveFileUuid,
  }) async {
    final resp = await request.post(
      '/chat/media',
      data: <String, dynamic>{
        'conversation_uuid': conversationUuid,
        'drive_file_uuid': driveFileUuid,
      },
    );
    final data = (resp.data is Map && (resp.data as Map)['data'] is Map)
        ? (resp.data as Map)['data'] as Map
        : resp.data as Map;
    return ChatMediaRef.fromJson(data.cast<String, dynamic>());
  }
}

class ChatMediaRef {
  ChatMediaRef({
    required this.refUuid,
    required this.driveFileUuid,
    required this.mediaKind,
    required this.sourceKind,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
  });

  /// chat media ref(授权单元;URL 用它)。
  final String refUuid;

  /// 底层 drive_files.uuid(溯源/import/去重;**非** URL 用途)。
  final String driveFileUuid;
  final int mediaKind; // 2=image, 8=file
  final String sourceKind;
  final String fileName;
  final String mimeType;
  final int sizeBytes;

  bool get isImage => mediaKind == 2;

  factory ChatMediaRef.fromJson(Map<String, dynamic> json) {
    final mk = json['media_kind'];
    final sz = json['size_bytes'];
    return ChatMediaRef(
      refUuid: (json['ref_uuid'] ?? '').toString(),
      driveFileUuid: (json['drive_file_uuid'] ?? '').toString(),
      mediaKind: mk is num ? mk.toInt() : 8,
      sourceKind: (json['source_kind'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      sizeBytes: sz is num ? sz.toInt() : 0,
    );
  }
}
