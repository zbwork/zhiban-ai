import 'package:file_selector/file_selector.dart';
import 'package:zhiban_client/services/device_media_actions.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

// Image extensions + UTIs shared across pickers.
const _imageExtensions = <String>[
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'heic',
  'bmp'
];
const _imageUtis = <String>['public.image'];

const _chatFileExtensions = <String>[
  'txt',
  'pdf',
  'xls',
  'xlsx',
  'doc',
  'docx',
  'jpg',
  'jpeg',
  'png',
  'gif',
  'bmp',
  'webp',
];
const _chatFileUtis = <String>[
  'public.plain-text',
  'com.adobe.pdf',
  'com.microsoft.excel.xls',
  'org.openxmlformats.spreadsheetml.sheet',
  'com.microsoft.word.doc',
  'org.openxmlformats.wordprocessingml.document',
  'public.image',
];

const knowledgeDocumentFormatHint =
    '知识库支持 TXT、Markdown、PDF、Word、Excel、PPT、CSV、JSON 以及 PNG、JPG、JPEG、GIF、TIF 图片';

const _knowledgeDocumentExtensions = <String>[
  'txt',
  'log',
  'md',
  'markdown',
  'csv',
  'json',
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'tif',
  'tiff',
];

const _knowledgeDocumentUtis = <String>[
  'public.plain-text',
  'net.daringfireball.markdown',
  'public.comma-separated-values-text',
  'public.json',
  'com.adobe.pdf',
  'com.microsoft.word.doc',
  'org.openxmlformats.wordprocessingml.document',
  'com.microsoft.excel.xls',
  'org.openxmlformats.spreadsheetml.sheet',
  'com.microsoft.powerpoint.ppt',
  'org.openxmlformats.presentationml.presentation',
  'public.image',
];

/// Pick a single image (avatar, profile photo, etc.).
/// Mobile → photo gallery via ImagePicker.
/// Desktop → file_selector filtered to image types.
Future<XFile?> pickSingleImage() async {
  if (PlatformUtils.isMobile) {
    return requireDeviceMediaActions().pickSingleImage();
  }
  const group = XTypeGroup(
    label: 'image',
    extensions: _imageExtensions,
    uniformTypeIdentifiers: _imageUtis,
  );
  return openFile(acceptedTypeGroups: [group]);
}

/// Pick one or more images only (photo gallery on mobile, image types on desktop).
Future<List<XFile>> pickImageFiles() async {
  if (PlatformUtils.isMobile) {
    return requireDeviceMediaActions().pickImages();
  }
  const group = XTypeGroup(
    label: 'images',
    extensions: _imageExtensions,
    uniformTypeIdentifiers: _imageUtis,
  );
  return openFiles(acceptedTypeGroups: [group]);
}

/// Take one photo with the device camera and return it as a chat image file.
Future<XFile?> takePhotoFile() async {
  if (!PlatformUtils.isMobile) return null;
  return requireDeviceMediaActions().takePhoto();
}

/// Pick one or more files for chat attachments (images + common docs).
/// Mobile → iOS Files app / Android file picker (allow all) via file_selector.
/// Desktop → file_selector with chat file types.
Future<List<XFile>> pickChatFiles() async {
  if (PlatformUtils.isMobile) {
    return openFiles(acceptedTypeGroups: [const XTypeGroup()]);
  }
  const group = XTypeGroup(
    label: 'chat-files',
    extensions: _chatFileExtensions,
    uniformTypeIdentifiers: _chatFileUtis,
  );
  return openFiles(acceptedTypeGroups: [group]);
}

bool isKnowledgeDocumentFileName(String fileName) {
  final lower = fileName.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return false;
  return _knowledgeDocumentExtensions.contains(lower.substring(dot + 1));
}

bool isKnowledgeDocumentMime(String mimeType) {
  final mime = mimeType.toLowerCase().trim();
  return mime == 'text/plain' ||
      mime == 'text/markdown' ||
      mime == 'text/md' ||
      mime == 'text/x-markdown' ||
      mime == 'text/csv' ||
      mime == 'application/json' ||
      mime == 'application/pdf' ||
      mime == 'application/msword' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      mime == 'application/vnd.ms-excel' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
      mime == 'application/vnd.ms-powerpoint' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
      mime == 'image/png' ||
      mime == 'image/jpeg' ||
      mime == 'image/jpg' ||
      mime == 'image/gif' ||
      mime == 'image/tif' ||
      mime == 'image/tiff' ||
      mime.startsWith('text/');
}

/// Pick a single file supported by knowledge-base ingestion.
Future<XFile?> pickKnowledgeDocumentFile() async {
  const group = XTypeGroup(
    label: 'knowledge-documents',
    extensions: _knowledgeDocumentExtensions,
    uniformTypeIdentifiers: _knowledgeDocumentUtis,
  );
  return openFile(acceptedTypeGroups: [group]);
}

/// Pick any single file (document upload, knowledge base, etc.).
/// Mobile → iOS Files app / Android file picker via file_selector (allow all).
/// Desktop → file_selector with no type restriction.
Future<XFile?> pickAnyFile() async {
  // XTypeGroup() with no args = allow all files on every platform.
  return openFile(acceptedTypeGroups: [const XTypeGroup()]);
}
