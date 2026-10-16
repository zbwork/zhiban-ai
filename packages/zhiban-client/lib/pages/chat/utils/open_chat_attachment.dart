import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> previewChatAttachment(BuildContext context, ChatFileItem file,
    {required WidgetRef ref}) async {
  final local = file.filePath?.trim() ?? '';
  var url = file.fileLink?.trim() ?? '';
  if (local.isNotEmpty && await File(local).exists()) {
    url = Uri.file(local).toString();
  }
  if (url.isEmpty && (file.driveFileUuid?.isNotEmpty ?? false)) {
    // Keep the stable Bus path so Refresh can issue a new signed URL.
    url = '/drive/files/${file.driveFileUuid}/preview';
  }
  if (!context.mounted) return;
  if (url.isEmpty) {
    BotToast.showText(text: '暂无可预览的文件');
    return;
  }
  await showAttachmentPreviewDialog(context,
      rawUrl: url, displayName: file.fileName);
}

/// 在系统/浏览器中打开聊天附件：本机文件在手机端用 [launchUrl]（[Uri.file]），桌面端用 [OpenFile]；
/// 远程链接走 [openProtectedOrPublicUrl]，以便受保护的 message-files / chat-media
/// 链接先带 token 换成可直接打开的下载地址。
///
/// 当 [file] 没有本地路径也没有 fileLink、但带 `driveFileUuid` 时(典型场景:
/// 数字员工产出的非图片文件 cmf.file_url=空,只在 drive_files 里),
/// 用 [ref] 调 `driveService.previewUrl(download: true)` 现签 S3 URL 再 launch。
/// 不传 [ref] 等同于走老链路,签 URL 步骤跳过。
Future<void> openChatAttachmentExternally(
  BuildContext context,
  ChatFileItem file, {
  WidgetRef? ref,
}) async {
  final path = file.filePath?.trim();
  if (!kIsWeb && path != null && path.isNotEmpty) {
    try {
      if (File(path).existsSync()) {
        if (PlatformUtils.isMobile) {
          final uri = Uri.file(path);
          final ok = await launchUrl(
            uri,
            mode: LaunchMode.externalApplication
          );
          if (!ok && context.mounted) {
            BotToast.showText(
              text: '无法打开文件',
              align: Alignment.center
            );
          }
        } else {
          final result = await OpenFile.open(path);
          if (!context.mounted) return;
          if (result.type != ResultType.done) {
            final msg = result.message.trim();
            BotToast.showText(
              text: msg.isNotEmpty ? msg : '无法打开文件',
              align: Alignment.center,
            );
          }
        }
        return;
      }
    } catch (_) {
      if (context.mounted) {
        BotToast.showText(
          text: '无法打开文件',
          align: Alignment.center
        );
      }
      return;
    }
  }

  final link = file.fileLink?.trim();
  if (link != null && link.isNotEmpty) {
    await openProtectedOrPublicUrl(link);
    return;
  }

  // 兜底:有 driveFileUuid 时,现签 S3 presigned URL 打开。
  // 适用于 assistant_output 非图片文件——cmf.file_url 为空,fileLink 没有,
  // 但 drive_files 里这条文件还在,/files/{uuid}/download 能签出可下载 URL。
  final driveUuid = file.driveFileUuid?.trim();
  if (ref != null && driveUuid != null && driveUuid.isNotEmpty) {
    try {
      final preview = await ref
          .read(driveServiceProvider)
          .previewUrl(fileUuid: driveUuid, download: true);
      final uri = Uri.tryParse(preview.url);
      if (uri != null) {
        final ok = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication
        );
        if (!ok && context.mounted) {
          BotToast.showText(text: '无法打开文件', align: Alignment.center);
        }
        return;
      }
    } catch (_) {
      if (context.mounted) {
        BotToast.showText(text: '无法获取文件下载链接', align: Alignment.center);
      }
      return;
    }
  }

  if (context.mounted) {
    BotToast.showText(
      text: '暂无可打开的路径',
      align: Alignment.center
    );
  }
}
