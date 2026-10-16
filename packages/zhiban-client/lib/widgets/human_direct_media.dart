import 'package:zhiban_ui/widgets/ui_image_hero.dart';
import 'dart:io';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/device_media_actions.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/chat/providers/chat_media_download_controller.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';
import 'package:share_plus/share_plus.dart';

/// 人↔人 WuKong 文件消息的媒体渲染（图片缩略图 / 文件卡片）。
///
/// 媒体 URL 是 agent-bus 受保护端点（`/chat/media/{ref}/preview|download`，
/// 302 → 签名 S3）。Bearer token 由 [UiNetworkImage] 自动注入，无需在此处理。

/// 把 chat media URL 拼成完整 http(s) URL。绝对 URL 透传;`/chat/media/...` /
/// `chat/media/...` 这种相对路径自动拼上 `AppConfig.apiUrl()`。
/// `@visibleForTesting` 仅给现有内部测试用; **P2 (2026-06) 也给 [ChatImagePreviewDialog]
/// 公开调用**(同 lib 内 helper, 与媒体渲染一致)。
@visibleForTesting
String resolveChatMediaUrl(String url) {
  final value = url.trim();
  if (value.isEmpty) return value;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (value.startsWith('/chat/media/')) {
    return '${AppConfig.apiUrl()}$value';
  }
  if (value.startsWith('chat/media/')) {
    return '${AppConfig.apiUrl()}/$value';
  }
  return value;
}

/// 公开包装 (P2 (2026-06)): 不带 `@visibleForTesting`,给同包内 widget 用。
String resolveChatMediaUrlPublic(String url) => resolveChatMediaUrl(url);

/// 解析出最终签名 S3 URL（用业务 dio,自动带 Bearer）。**fail-closed**:
/// 拿不到签名 URL 就抛错,**绝不**回退用原始 Bus URL 去 launch（外部浏览器无 Bearer
/// 必失败,且可能误开内部端点）。参考 `drive_service.previewUrl`。
///
/// 端点行为:`Accept: application/json` → 返 `{success,code,data:{url}}`;否则 302 + Location。
/// 这里显式要 JSON,直接取 `data.url`,避免 dio 跟随 302 拉二进制 / 误把 Bus URL 当结果。
Future<String> _resolveSignedUrl(String url) async {
  final resolved = resolveChatMediaUrl(url);
  final resp = await request.get<dynamic>(
    resolved,
    options: Options(
      headers: {'Accept': 'application/json'},
      followRedirects: false,
      validateStatus: (s) => s != null && s < 400,
    ),
  );
  final data = resp.data;
  String signed = '';
  if (data is Map) {
    final inner = (data['data'] is Map) ? data['data'] as Map : data;
    signed = (inner['url'] ?? '').toString();
  }
  // 兜底:某些环境仍只给 302 + Location（无 JSON body）。
  if (signed.isEmpty) {
    signed = resp.headers.value('location') ?? '';
  }
  if (signed.isEmpty || signed == resolved) {
    throw StateError('chat media: no signed url resolved');
  }
  return signed;
}

@visibleForTesting
Future<bool> looksLikeImageFile(File file) async {
  try {
    final raf = await file.open();
    try {
      final header = await raf.read(16);
      return isImageMagicBytes(header);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}

@visibleForTesting
bool isImageMagicBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return true; // JPEG
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true; // PNG
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true; // GIF87a / GIF89a
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return true; // BMP
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true; // WEBP (RIFF....WEBP)
  }
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (const {'heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1', 'heim', 'heis'}
        .contains(brand)) {
      return true; // HEIC/HEIF (ISOBMFF ftyp box)
    }
  }
  return false;
}

@visibleForTesting
String sanitizeChatDownloadFileName(String raw) {
  final normalized = raw
      .replaceAll(RegExp(r'[\x00-\x1F\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty || normalized == '.' || normalized == '..') {
    return '文件';
  }
  return normalized;
}

@visibleForTesting
File uniqueChatDownloadTarget(Directory dir, String fileName) {
  final safe = sanitizeChatDownloadFileName(fileName);
  final dot = safe.lastIndexOf('.');
  final hasExt = dot > 0 && dot < safe.length - 1;
  final stem = hasExt ? safe.substring(0, dot) : safe;
  final ext = hasExt ? safe.substring(dot) : '';

  File candidate(int suffix) {
    final name = suffix == 0 ? safe : '$stem ($suffix)$ext';
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  var file = candidate(0);
  var suffix = 1;
  while (file.existsSync()) {
    file = candidate(suffix);
    suffix += 1;
  }
  return file;
}

@visibleForTesting
class ChatRevealCommand {
  const ChatRevealCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

@visibleForTesting
ChatRevealCommand? revealChatDownloadCommand(
  String filePath, {
  String? platform,
}) {
  final targetPlatform = platform ??
      (Platform.isMacOS
          ? 'macos'
          : Platform.isWindows
              ? 'windows'
              : Platform.isLinux
                  ? 'linux'
                  : 'other');
  if (targetPlatform == 'macos') {
    return ChatRevealCommand('open', ['-R', filePath]);
  }
  if (targetPlatform == 'windows') {
    return ChatRevealCommand('explorer.exe', ['/select,$filePath']);
  }
  if (targetPlatform == 'linux') {
    return ChatRevealCommand(
      'xdg-open',
      [File(filePath).parent.path]
    );
  }
  return null;
}

Future<Directory> _chatDownloadsDirectory() async {
  if (PlatformUtils.isMobile) {
    return getTemporaryDirectory();
  }

  final downloads = await getDownloadsDirectory();
  if (downloads != null) {
    await downloads.create(recursive: true);
    return downloads;
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (home.isNotEmpty) {
    final fallback = Directory('$home${Platform.pathSeparator}Downloads');
    await fallback.create(recursive: true);
    return fallback;
  }

  final fallback = Directory.systemTemp.createTempSync('easyo-downloads-');
  return fallback;
}

Future<File> _downloadChatFileToDownloads({
  required String url,
  required String name,
  void Function(int received, int total)? onReceiveProgress,
  CancelToken? cancelToken,
}) async {
  final signed = await _resolveSignedUrl(url);
  final dir = await _chatDownloadsDirectory();
  final target = uniqueChatDownloadTarget(dir, name.isEmpty ? '文件' : name);
  await Dio().download(
    signed,
    target.path,
    options: Options(responseType: ResponseType.bytes),
    onReceiveProgress: onReceiveProgress,
    cancelToken: cancelToken,
  );
  return target;
}

/// F09 C 公开入口:从消息菜单「保存文件」/「打开位置」触发。
///
/// 桌面:下载到系统下载目录(去重命名),并 best-effort reveal in 文件管理器。
/// 移动端:没有可写入的公共"下载目录",图片走系统相册 (`Gal`),文件走系统分享面板
/// (`SharePlus`) 让用户自己选保存位置 / 目标 App。
///
/// 返回最终落地文件,失败抛错。
Future<File> downloadChatMediaToDownloads({
  required String url,
  required String name,
  bool reveal = true,
  bool isImage = false,
  void Function(int received, int total)? onReceiveProgress,
  CancelToken? cancelToken,
}) async {
  final file = await _downloadChatFileToDownloads(
    url: url,
    name: name,
    onReceiveProgress: onReceiveProgress,
    cancelToken: cancelToken,
  );
  if (PlatformUtils.isMobile) {
    if (isImage || await looksLikeImageFile(file)) {
      await requireDeviceMediaActions().saveImage(file.path);
    } else {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: name),
      );
    }
    return file;
  }
  if (reveal) {
    await _revealDownloadedFile(file);
  }
  return file;
}

/// 桌面端 reveal-only 入口 (不下载, 已知本地文件直接定位)。
Future<void> revealChatDownloadedFile(File file) => _revealDownloadedFile(file);

Future<void> _revealDownloadedFile(File file) async {
  if (kIsWeb) return;
  final command = revealChatDownloadCommand(file.path);
  if (command == null) return;
  try {
    await Process.run(command.executable, command.arguments);
  } catch (_) {
    // reveal 只是便利动作,下载成功本身不应因为系统文件管理器不可用而报失败。
  }
}

/// 图片气泡缩略图：带鉴权头加载；点击触发外部 [onTap] (P2 (2026-06) 接 ChatImagePreviewDialog)。
///
/// 默认 [onTap]=null 时回退**单图 fallback** overlay (与原行为兼容: dialog + InteractiveViewer);
/// 调用方传 [onTap] 后,可以打开多图预览 (上下张切换 + 保存)。
class HumanDirectMediaImage extends StatelessWidget {
  const HumanDirectMediaImage({
    super.key,
    required this.url,
    this.heroName,
    this.onTap,
    this.onPreviewWithHero,
  });

  final String url;
  final String? heroName;

  /// 外部 tap 入口 (P2 多图预览)。null = 回退既有单图 dialog。
  final VoidCallback? onTap;
  final ValueChanged<Object>? onPreviewWithHero;

  @override
  Widget build(BuildContext context) {
    final imageUrl = resolveChatMediaUrl(url);
    return UiImageHero(
        builder: (context, heroTag) => GestureDetector(
              onTap: onPreviewWithHero != null
                  ? () => onPreviewWithHero!(heroTag)
                  : onTap ?? () => _openFallbackPreview(context, heroTag),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 220, maxHeight: 260),
                  child: UiNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    borderRadius: 8,
                    placeholderBuilder: (_, __) => const SizedBox(
                      width: 160,
                      height: 120,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    errorBuilder: (_, __, ___) => _broken(),
                  ),
                ),
              ),
            ));
  }

  void _openFallbackPreview(BuildContext context, Object heroTag) {
    final imageUrl = resolveChatMediaUrl(url);
    if (tryOpenChatImagePreview(context, rawUrl: imageUrl)) return;
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.android) {
      showImagePreviewRoute<void>(
        context: context,
        useSafeArea: Theme.of(context).platform != TargetPlatform.iOS &&
            Theme.of(context).platform != TargetPlatform.android,
        barrierColor: Colors.black87,
        builder: (_) =>
            UiImagePreviewDialog(fileUrl: imageUrl, heroTag: heroTag),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: InteractiveViewer(
          child: Center(
            child: UiNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.contain,
              borderRadius: 0,
              errorBuilder: (_, __, ___) => _broken(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _broken() => Container(
        width: 160,
        height: 120,
        color: const Color(0xFFF2F3F5),
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined,
            color: Color(0xFF98A2B3), size: 28),
      );
}

/// 文件气泡卡片：图标 + 名称 + 大小；双击/单击下载到系统下载目录并定位。
///
/// **P2 (2026-06) 增量**:
/// - 接 `ChatMediaDownloadController` 监听同 URL 下载进度,卡片底部出现 progress bar + 百分比文案;
/// - 同 URL 重复点击 → controller 内部 fail-fast (toast「该文件已在下载中」), 不并发下载;
/// - 完成态/失败态 30s 内 UI 保留状态行,然后回到 idle (可再触发)。
///
/// **CR-2026-06**: 不要用外层 `GestureDetector` 包本卡片拦截 tap (会和内部 GestureDetector
/// 竞争, tester.tap / 真实用户点击不可靠)。需要替换 tap 行为时,传 [onOpen] 回调:
/// 非空时内部 tap/双击直接调 `onOpen` (调用方负责 video 打开 / 自定义路径),
/// 否则回退原 download 链路 (`ChatMediaDownloadController.start`)。
/// [mime] / [isVideoOverride] 用于视频角标判定: `isVideo = isVideoOverride ?? (isVideoFileName(name) || isVideoMime(mime))`,
/// 这样 mime-only 的视频 (文件名无扩展但 mime=video/*) 也能正确显示紫色 play 角标。
class HumanDirectFileCard extends ConsumerWidget {
  const HumanDirectFileCard({
    super.key,
    required this.url,
    required this.name,
    required this.size,
    this.mime = '',
    this.isVideoOverride,
    this.onOpen,
  });

  final String url;
  final String name;
  final int size;

  /// 文件 MIME (用于视频角标判定;mime 优先于文件名扩展)。
  final String mime;

  /// 调用方明确告知本卡片是否为视频 (例如 mixed bubble 用 `isVideoMessage(parent)`)。
  /// null = 卡片自己按 name + mime 判定。
  final bool? isVideoOverride;

  /// 替换默认 tap/双击行为: 非空时调 `onOpen` (调用方可走视频打开 / 自定义 download / 等);
  /// null 时回退原下载链路 (`ChatMediaDownloadController.start`)。
  final VoidCallback? onOpen;

  bool get _isVideo =>
      isVideoOverride ?? (isVideoFileName(name) || isVideoMime(mime));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.watch(chatMediaDownloadControllerProvider);
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => _buildBody(context, ref, ctl),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    ChatMediaDownloadController ctl,
  ) {
    final task = ctl.taskOf(url);
    final isVideo = _isVideo;
    final iconColor =
        isVideo ? const Color(0xFF8B5CF6) : const Color(0xFF2563EB);
    final iconBg = isVideo ? const Color(0xFFF4EEFF) : const Color(0xFFEFF4FF);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => _handleTap(context, ref),
        onTap: () => _handleTap(context, ref),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFEAEAEA)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: iconBg,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: FileAttachmentIcon(
                          fileName: name,
                          size: FileAttachmentIconSize.lg,
                          fallbackIconColor: iconColor,
                        ),
                      ),
                      if (isVideo)
                        Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Color(0xFF8B5CF6),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(CupertinoIcons.play_fill,
                              size: 10, color: Colors.white),
                        ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? (isVideo ? '视频' : '文件') : name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1D2129),
                            height: 1.3,
                          ),
                        ),
                        if (size > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            _humanFileSize(size),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF98A2B3),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (task != null && task.status != ChatMediaDownloadStatus.idle)
                _CardDownloadStatusRow(task: task),
            ],
          ),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, WidgetRef ref) {
    if (!_isVideo && AttachmentPreviewScope.of(context) != null) {
      showAttachmentPreviewDialog(context,
          rawUrl: resolveChatMediaUrl(url), displayName: name, mime: mime);
      return;
    }
    final cb = onOpen;
    if (cb != null) {
      cb();
      return;
    }
    final ctl = ref.read(chatMediaDownloadControllerProvider);
    // ignore: discarded_futures
    ctl.start(url: url, name: name.isEmpty ? '文件' : name);
  }
}

class _CardDownloadStatusRow extends StatelessWidget {
  const _CardDownloadStatusRow({required this.task});
  final ChatMediaDownloadTask task;

  @override
  Widget build(BuildContext context) {
    final color = task.status == ChatMediaDownloadStatus.failed
        ? const Color(0xFFE53935)
        : task.status == ChatMediaDownloadStatus.completed
            ? const Color(0xFF22A06B)
            : const Color(0xFF2563EB);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: task.fraction,
            minHeight: 3,
            backgroundColor: const Color(0xFFEFF1F5),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
          const SizedBox(height: 4),
          Text(task.progressLabel,
              style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

String _humanFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
