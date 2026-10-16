import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/services/message_files_api.dart';

class _FakeMessageFilesService extends MessageFilesService {
  _FakeMessageFilesService(this.resultUuid);

  final String resultUuid;
  String? lastFilePath;
  String? lastFileName;
  String? lastMimeType;
  int uploadCalls = 0;

  @override
  Future<String> uploadFile({
    required String filePath,
    required String fileName,
    required String mimeType,
    String? conversationUuid,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    uploadCalls += 1;
    lastFilePath = filePath;
    lastFileName = fileName;
    lastMimeType = mimeType;
    return resultUuid;
  }
}

void main() {
  group('OpenClawChatService.uploadFile', () {
    test('uploads pasted image through message-files and returns preview URL',
        () async {
      final files = _FakeMessageFilesService('file-img-1');
      final service = OpenClawChatService(messageFiles: files);

      final result = await service.uploadFile(
        ChatFileItem(
          fileName: 'clipboard.png',
          filePath: '/tmp/clipboard.png',
          fileType: ChatFileType.image,
        ),
      );

      expect(files.uploadCalls, 1);
      expect(files.lastFilePath, '/tmp/clipboard.png');
      expect(files.lastFileName, 'clipboard.png');
      expect(files.lastMimeType, 'image/png');
      expect(result.uuid, 'file-img-1');
      expect(result.driveFileUuid, 'file-img-1');
      expect(result.url, '/message-files/file-img-1/preview');
    });

    test('uploads spreadsheet through message-files and returns download URL',
        () async {
      final files = _FakeMessageFilesService('file-sheet-1');
      final service = OpenClawChatService(messageFiles: files);

      final result = await service.uploadFile(
        ChatFileItem(
          fileName: '30天学习汉语计划.xlsx',
          filePath: '/tmp/30天学习汉语计划.xlsx',
          fileType: ChatFileType.file,
        ),
      );

      expect(files.lastMimeType,
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      expect(result.uuid, 'file-sheet-1');
      expect(result.driveFileUuid, 'file-sheet-1');
      expect(result.url, '/message-files/file-sheet-1/download');
    });

    test('rejects empty local file path before upload', () async {
      final files = _FakeMessageFilesService('unused');
      final service = OpenClawChatService(messageFiles: files);

      expect(
        () => service.uploadFile(
          ChatFileItem(
            fileName: 'clipboard.png',
            fileType: ChatFileType.image
          ),
        ),
        throwsA(isA<Exception>()),
      );
      expect(files.uploadCalls, 0);
    });
  });
}
