import 'package:zhiban_core/im/im_client.dart';

/// F09 P2 媒体消息体验 (2026-06): 视频消息客户端识别.
///
/// 见 `docs/contracts/agent-bus-client-contract.md` §「媒体消息体验 / 视频消息基础支持」.
///
/// **wire 仍是 `ImMediaKind.file`** (后端 chat_media_ref 不感知 video kind);
/// 客户端展示阶段按 `mime startsWith video/` + 常见扩展识别,把 file 消息展示为「视频卡片」。
/// 这样不动 enum、不动后端、不改 `_upsert` / `_classifyKind` 任何 switch 分支。
///
/// 仅用于**展示** + **历史媒体 tab 归类** + **菜单 fail-closed** (转发隐藏 video);
/// 发送 / 历史解析 / 去重链路全部走原来的 `ImMediaKind.file` 路径不动。

const Set<String> _videoExtensions = <String>{
  'mp4',
  'mov',
  'm4v',
  'webm',
  'avi',
  'mkv',
  'mpg',
  'mpeg',
  '3gp',
  'wmv',
  'ogv',
};

/// 文件名末尾扩展是否是常见视频格式 (大小写不敏感).
bool isVideoFileName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  final dot = trimmed.lastIndexOf('.');
  if (dot < 0 || dot >= trimmed.length - 1) return false;
  final ext = trimmed.substring(dot + 1).toLowerCase();
  return _videoExtensions.contains(ext);
}

/// MIME 是否是 video/* (mp4/mov/webm 等).
bool isVideoMime(String mime) {
  final m = mime.trim().toLowerCase();
  return m.startsWith('video/');
}

/// 该消息**展示态**是否应作为「视频」处理:
/// 顶层 file 媒体的 mime 是 video/ 或文件名扩展是常见视频格式 → true。
/// **不**改 `mediaKind` 本身, 仍是 `file`;仅展示分流 (气泡 / 历史 / 菜单)。
bool isVideoMessage(ImMessage m) {
  // 顶层 file 媒体: 直接看 mime / mediaName。
  if (m.mediaKind == ImMediaKind.file) {
    if (isVideoMime(m.mediaMime)) return true;
    if (isVideoFileName(m.mediaName)) return true;
    if (isVideoFileName(m.text)) return true; // 回退 (媒体 text 偶尔携带文件名)
    return false;
  }
  // mixed payload: 只有当 mixed 内**唯一**媒体 block 是 file 且符合视频 mime/扩展时算视频。
  // 含多个 file / image / 文本 block 的 mixed 不算「视频消息」(避免气泡分流歧义)。
  if (m.isMixed) {
    final fileBlocks = <ImMessageBlock>[];
    var hasImage = false;
    for (final b in m.blocks) {
      if (b.isImage) hasImage = true;
      if (b.isFile) fileBlocks.add(b);
    }
    if (hasImage) return false;
    if (fileBlocks.length != 1) return false;
    final b = fileBlocks.single;
    return isVideoMime(b.mime) || isVideoFileName(b.name);
  }
  return false;
}

/// 该消息**展示态**是否应作为「图片」处理 (用于历史 media tab + 大图预览收集)。
/// 顶层 image 媒体 / mixed 内含 image block 均算。
bool isImageMessage(ImMessage m) {
  if (m.mediaKind == ImMediaKind.image) return true;
  if (m.isMixed) {
    for (final b in m.blocks) {
      if (b.isImage) return true;
    }
  }
  return false;
}

const Set<String> _imageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'heic',
  'heif',
  'bmp',
};

/// 文件名末尾扩展是否是常见图片格式 (大小写不敏感)。
bool isImageFileName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  final dot = trimmed.lastIndexOf('.');
  if (dot < 0 || dot >= trimmed.length - 1) return false;
  final ext = trimmed.substring(dot + 1).toLowerCase();
  return _imageExtensions.contains(ext);
}

/// MIME 是否是 image/* 。
bool isImageMime(String mime) => mime.trim().toLowerCase().startsWith('image/');

/// 保存/下载场景用:不管消息走的是「图片」还是「文件」通道,只要内容本身看起来
/// 是图片 (mime 或扩展名) 就该按图片处理 (存相册, 而不是走文件分享)。
bool looksLikeSavableImage(ImMessage m) {
  if (m.mediaKind == ImMediaKind.image) return true;
  if (m.mediaKind != ImMediaKind.file) return false;
  return isImageMime(m.mediaMime) || isImageFileName(m.mediaName);
}

/// 历史「图片与视频」tab 是否应展示该消息: image **或** video。
bool isHistoryMediaMessage(ImMessage m) =>
    isImageMessage(m) || isVideoMessage(m);
