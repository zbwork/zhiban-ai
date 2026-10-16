import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'attachment_preview_loader.dart';
import 'attachment_preview_target.dart';

/// Local references must retain the snapshot identity even if a block also
/// supplies a download URL. Cloud files may have a separate original URL.
AttachmentPreviewTarget artifactDownloadTarget(
        AttachmentPreviewTarget target) =>
    AttachmentPreviewTarget(
        url: Uri.tryParse(target.url)?.scheme == 'local-artifact'
            ? target.url
            : (target.downloadUrl?.trim().isNotEmpty ?? false)
                ? target.downloadUrl!.trim()
                : target.url,
        name: target.name,
        mime: target.mime);

/// Both card and preview actions use authorized bytes and snapshot validation.
Future<void> downloadChatArtifact(
    BuildContext context, AttachmentPreviewTarget target,
    {bool openAfterSave = false}) async {
  final name = target.name.isEmpty ? '附件' : target.name;
  final location = PlatformUtils.isDesktop
      ? await getSaveLocation(suggestedName: name)
      : null;
  if (PlatformUtils.isDesktop && location == null) return;
  final loader = AttachmentPreviewLoader();
  try {
    final bytes = await loader.read(artifactDownloadTarget(target),
        attachmentPreviewFormat(target.name, target.url, target.mime),
        maxBytes: 128 * 1024 * 1024);
    if (location != null) {
      await XFile.fromData(bytes, name: name).saveTo(location.path);
      if (openAfterSave) {
        if (Platform.isMacOS) {
          final result = await Process.run('open', [location.path]);
          if (result.exitCode != 0) throw StateError('无法打开已保存的文件');
        } else if (!await launchUrl(Uri.file(location.path),
            mode: LaunchMode.externalApplication)) {
          throw StateError('无法打开已保存的文件');
        }
      }
    } else {
      if (!context.mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [
          XFile.fromData(bytes,
              mimeType: target.mime.isEmpty ? null : target.mime)
        ],
        fileNameOverrides: [name],
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    }
  } finally {
    loader.dispose();
  }
}
