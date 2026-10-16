import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

/// An opaque source identifier, never an OS path or a cloud download URL.
class LocalArtifactSource {
  const LocalArtifactSource(
      {required this.artifactId,
      required this.deviceId,
      required this.sha256,
      required this.conversationId,
      this.archiveStatus = '',
      this.driveFileId = ''});
  final String artifactId;
  final String deviceId;
  final String sha256;
  final String conversationId;
  final String archiveStatus;
  final String driveFileId;
  String? get cloudUrl => _uuid.hasMatch(driveFileId)
      ? '/drive/files/$driveFileId/preview?sha256=$sha256'
      : null;
  static final _uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static LocalArtifactSource? fromBlock(
      Map<String, dynamic> block, String conversation) {
    final ref = block['local_artifact'];
    if (ref is! Map) return null;
    final artifact = '${ref['artifact_id'] ?? ''}';
    final device = '${ref['device_id'] ?? ''}';
    final hash = '${ref['sha256'] ?? ''}';
    if (!_uuid.hasMatch(artifact) ||
        !_uuid.hasMatch(device) ||
        !_uuid.hasMatch(conversation) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      return null;
    }
    return LocalArtifactSource(
        artifactId: artifact,
        deviceId: device,
        sha256: hash,
        conversationId: conversation,
        archiveStatus: '${block['archive_status'] ?? ''}',
        driveFileId: '${block['drive_file_id'] ?? ''}');
  }

  String get url => Uri(
          scheme: 'local-artifact',
          host: deviceId,
          path: '/$artifactId',
          queryParameters: {
            'sha256': sha256,
            'conversation': conversationId,
            if (cloudUrl != null) 'drive_file_id': driveFileId
          }).toString();

  static LocalArtifactSource? parse(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'local-artifact' ||
        uri.pathSegments.length != 1 ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty ||
        !uri.queryParameters.keys.every((key) =>
            ['sha256', 'conversation', 'drive_file_id'].contains(key))) {
      return null;
    }
    return fromBlock({
      'drive_file_id': uri.queryParameters['drive_file_id'] ?? '',
      'local_artifact': {
        'artifact_id': uri.pathSegments.single,
        'device_id': uri.host,
        'sha256': uri.queryParameters['sha256']
      }
    }, uri.queryParameters['conversation'] ?? '');
  }

  Map<String, dynamic> toRequest() => {
        'artifact_id': artifactId,
        'device_id': deviceId,
        'sha256': sha256,
        'conversation': conversationId
      };
}

/// Both original-device reads and archived copies must match the immutable reference.
void verifyArtifactHash(Uint8List bytes, String expected,
    {String message = '本地产物内容校验失败'}) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected) ||
      crypto.sha256.convert(bytes).toString() != expected) {
    throw StateError(message);
  }
}
