import 'dart:io';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_image_preview.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/folder_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 消息气泡内附件区域：图片缩略图 + 非图片文档条。
class MessageBubbleFileAttachments extends StatelessWidget {
  const MessageBubbleFileAttachments({
    super.key,
    required this.files,
    this.onOpenAttachment,
    this.alignment = CrossAxisAlignment.end,
  });

  final List<ChatFileItem> files;
  final ValueChanged<ChatFileItem>? onOpenAttachment;

  /// 附件横向对齐：用户气泡靠右(end)，assistant 气泡靠左(start)。
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignment,
      spacing: 8,
      children: [
        ...files.map((f) {
          if (f.fileType == ChatFileType.image) {
            return MessageBubbleImageAttachment(file: f);
          }
          return MessageBubbleDocumentAttachment(
            file: f,
            onOpenAttachment: onOpenAttachment,
          );
        }),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 气泡内图片附件：固定高度、宽度随比例变化（上限 [kMessageBubbleImageMaxWidth]），点击大图预览。
const double kMessageBubbleImageHeight = 120;
const double kMessageBubbleImageMaxWidth = 280;

class MessageBubbleImageAttachment extends ConsumerWidget {
  const MessageBubbleImageAttachment({super.key, required this.file});

  final ChatFileItem file;

  static Widget _errorPlaceholder(double h, [double w = 56]) {
    return SizedBox(
      width: w,
      height: h,
      child: const Center(
        child: Icon(CupertinoIcons.photo, color: Color(0xFF94A3B8)),
      ),
    );
  }

  /// 与 [UiImagePreviewThumb] 一致：本机仍存在时优先本地，避免 URL 切换闪一下。
  ///
  /// 网络图分两种 URL 形态:
  ///   - 公网 URL(http(s)://...) —— 直接拉,不用 token;
  ///   - ai-office 自家相对路径 `/app/openclaw-drive/files/<uuid>/preview` ——
  ///     必须补全 baseURL + 带 Bearer token。CachedNetworkImage 默认不会从
  ///     dio 拦截器拿 token,所以这里走 [apiImageLoadHeaders] 主动注入。
  Widget _image(double h) {
    final path = file.filePath?.trim();
    if (path != null && path.isNotEmpty) {
      try {
        if (File(path).existsSync()) {
          return Image.file(
            File(path),
            height: h,
            fit: BoxFit.fitHeight,
            alignment: Alignment.centerLeft,
            errorBuilder: (_, __, ___) => _errorPlaceholder(h),
          );
        }
      } catch (_) {}
    }
    final url = file.fileLink?.trim();
    if (url == null || url.isEmpty) return _errorPlaceholder(h);
    final absoluteUrl = apiImageResolveUrl(url);
    return UiNetworkImage(
      imageUrl: absoluteUrl,
      cacheKey: absoluteUrl,
      height: h,
      fit: BoxFit.fitHeight,
      alignment: Alignment.centerLeft,
      clip: false,
      placeholderBuilder: (_, __) => _errorPlaceholder(h),
      errorBuilder: (_, __, ___) => _errorPlaceholder(h),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = kMessageBubbleImageHeight;
    final url = file.fileLink?.trim() ?? '';
    return UiImageHero(
        builder: (context, heroTag) => GestureDetector(
              onTap: () async {
                final local = file.filePath?.trim() ?? '';
                if (tryOpenChatImagePreview(context,
                    rawUrl: local.isNotEmpty && File(local).existsSync()
                        ? Uri.file(local).toString()
                        : url,
                    displayName: file.fileName)) {
                  return;
                }
                // 大图预览也要带 token,否则点开就是黑屏。
                final headers =
                    url.isEmpty ? null : await apiImageLoadHeaders(url);
                if (!context.mounted) return;
                showImagePreviewRoute<void>(
                  context: context,
                  useSafeArea:
                      Theme.of(context).platform != TargetPlatform.iOS &&
                          Theme.of(context).platform != TargetPlatform.android,
                  builder: (_) => UiImagePreviewDialog(
                    heroTag: heroTag,
                    filePath: file.filePath,
                    fileUrl: url.isEmpty ? null : apiImageResolveUrl(url),
                    httpHeaders: (headers != null && headers.isNotEmpty)
                        ? headers
                        : null,
                  ),
                );
              },
              onLongPress: file.cmfId != null
                  ? () => _showAttachmentMenu(context, ref, file)
                  : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: Colors.transparent,
                  child: SizedBox(
                    height: h,
                    child: ClipRect(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: kMessageBubbleImageMaxWidth,
                        ),
                        child: IntrinsicWidth(child: _image(h)),
                      ),
                    ),
                  ),
                ),
              ),
            ));
  }
}

/// 气泡内非图片文件（蓝色条，外链打开）。
class MessageBubbleDocumentAttachment extends ConsumerWidget {
  const MessageBubbleDocumentAttachment({
    super.key,
    required this.file,
    this.onOpenAttachment,
  });

  final ChatFileItem file;
  final ValueChanged<ChatFileItem>? onOpenAttachment;

  static const Color _chipColor = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = file.fileLink?.trim();
    final path = file.filePath?.trim();
    final canTryOpen =
        (link != null && link.isNotEmpty) || (path != null && path.isNotEmpty);
    return Material(
      color: _chipColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: !canTryOpen || onOpenAttachment == null
            ? null
            : () => onOpenAttachment?.call(file),
        onLongPress: file.cmfId != null
            ? () => _showAttachmentMenu(context, ref, file)
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FileAttachmentIcon(
                fileName: file.fileName,
                size: FileAttachmentIconSize.lg,
                fallbackIconColor: Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  file.fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
//  长按菜单:保存到云盘(走 importFromChat)
// ============================================================

void _showAttachmentMenu(
    BuildContext context, WidgetRef ref, ChatFileItem file) {
  if (file.cmfId == null) return;
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(CupertinoIcons.cloud_download),
              title: const Text('保存到云盘'),
              onTap: () async {
                Navigator.pop(ctx);
                await _saveToDriveFlow(context, ref, file);
              },
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _saveToDriveFlow(
    BuildContext context, WidgetRef ref, ChatFileItem file) async {
  // 新后端按单个 drive_file_uuid 导入(scope=chat 的 drive_files 行)。
  final driveUuid =
      (file.driveFileUuid != null && file.driveFileUuid!.isNotEmpty)
          ? file.driveFileUuid!
          : (file.uuid ?? '');
  if (driveUuid.isEmpty) return;
  final targetUuid = await showFolderPickerDialog(
    context,
    ref,
    title: '选择目标目录',
  );
  if (targetUuid == null || targetUuid.isEmpty) return;
  try {
    await ref.read(driveServiceProvider).importFromChat(
      targetFolderUuid: targetUuid,
      driveFileUuids: [driveUuid],
    );
    BotToast.showText(text: '已保存到云盘');
  } catch (e) {
    BotToast.showText(text: '保存失败:$e');
  }
}
