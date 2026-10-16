import 'dart:io' show Platform, Process;
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'file_preview/local_artifact_source.dart';
import 'package:zhiban_client/services/local_agent_service.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'file_preview/attachment_preview_target.dart';
import 'file_preview/attachment_preview_panel.dart';

/// Desktop chat images share the document pane; other surfaces keep their viewer.
bool tryOpenChatImagePreview(
  BuildContext context, {
  required String rawUrl,
  String displayName = '',
  String mime = '',
  String? downloadUrl,
}) {
  final scope = AttachmentPreviewScope.of(context);
  if (scope == null || rawUrl.trim().isEmpty) return false;
  final url = rawUrl.trim();
  final path = Uri.tryParse(url)?.path ?? url;
  final name =
      displayName.trim().isNotEmpty ? displayName.trim() : path.split('/').last;
  scope.open(AttachmentPreviewTarget(
    url: normalizeAttachmentPreviewUrl(url),
    name: name.isEmpty ? '图片' : name,
    mime: mime.startsWith('image/')
        ? mime
        : (name.toLowerCase().endsWith('.svg') ||
                path.toLowerCase().endsWith('.svg'))
            ? 'image/svg+xml'
            : 'image/*',
    downloadUrl: downloadUrl ?? url,
  ));
  return true;
}

/// 打开或下载附件 URL。
///
/// 受保护的 `/message-files/...` 等业务 URL 需要先用带 token 的 Dio 请求拿
/// 302 Location，再交给系统浏览器/默认应用；公网 URL 直接打开。
Future<void> openProtectedOrPublicUrl(String rawUrl,
    {String? displayName}) async {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return;

  final source = LocalArtifactSource.parse(trimmed);
  if (source != null) {
    try {
      await LocalAgentService.instance
          .saveArtifact(source, name: displayName ?? '本地产物');
    } catch (_) {
      BotToast.showText(text: '本地产物暂不可用，请保持原电脑登录');
    }
    return;
  }
  final String openTarget;
  try {
    openTarget = await resolveProtectedOrPublicUrl(trimmed);
  } catch (_) {
    BotToast.showText(text: '无法获取文件下载链接', align: Alignment.center);
    return;
  }

  if (Platform.isMacOS) {
    try {
      await Process.run('open', [openTarget]);
      return;
    } catch (_) {}
  }

  final uri = Uri.tryParse(openTarget);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// 解析可被外部浏览器/默认应用直接打开的 URL。
///
/// 对受保护的 Bus 文件 URL,显式要求 JSON 响应并读取 `data.url`,避免解析失败时
/// 把 `/message-files/...` 这种需要 Bearer 的内部接口裸交给外部浏览器。
Future<String> resolveProtectedOrPublicUrl(String rawUrl) async {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) {
    throw StateError('empty url');
  }
  if (!apiImageNeedsAuth(trimmed)) {
    return trimmed;
  }

  final resolved = apiImageResolveUrl(trimmed);
  final resp = await request.get<dynamic>(
    resolved,
    options: Options(
      headers: {'Accept': 'application/json'},
      followRedirects: false,
      validateStatus: (s) => s != null && s < 400,
    ),
  );

  var signed = '';
  final data = resp.data;
  if (data is Map) {
    final inner = data['data'] is Map ? data['data'] as Map : data;
    signed = (inner['url'] ?? '').toString().trim();
  }
  if (signed.isEmpty) {
    signed = (resp.headers.value('location') ?? '').trim();
  }
  if (signed.isEmpty || signed == resolved) {
    throw StateError('no signed url resolved');
  }
  return signed;
}

/// 将旧消息里只提供的 `/message-files/{uuid}/download` 归一为预览地址。
///
/// 保留 origin、query 和 fragment；非 message-files 下载地址原样返回。
String normalizeAttachmentPreviewUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.pathSegments.length < 3) return trimmed;
  final segments = [...uri.pathSegments];
  final fileIndex = segments.length - 3;
  if (segments[fileIndex] != 'message-files' || segments.last != 'download') {
    return trimmed;
  }
  final previewPath = '${uri.path.substring(0, uri.path.length - 8)}preview';
  return uri.replace(path: previewPath).toString();
}

/// 桌面聊天使用共享侧栏；手机 push 全屏预览，其他桌面场景回退弹框。
/// 保留此入口以复用现有文件卡片。授权下载及本地渲染由预览面板负责，
/// 原始下载 URL 与归一化后的预览 URL 分开保存。
Future<void> showAttachmentPreviewDialog(
  BuildContext context, {
  required String rawUrl,
  required String displayName,
  String mime = '',
  String? downloadUrl,
}) async {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return;
  final previewUrl = normalizeAttachmentPreviewUrl(trimmed);

  final target = AttachmentPreviewTarget(
      url: previewUrl,
      name: displayName,
      mime: mime,
      downloadUrl: downloadUrl ?? trimmed);
  final scope = AttachmentPreviewScope.of(context);
  if (scope != null) {
    scope.open(target);
    return;
  }
  if (PlatformUtils.isMobile) {
    await context.push<void>(RoutePaths.chatAttachmentPreview, extra: target);
    return;
  }
  await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(16),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
                width: 1000,
                height: MediaQuery.sizeOf(ctx).height * .85,
                child: AttachmentPreviewPanel(
                    target: target, onClose: () => Navigator.of(ctx).pop(),),
          ),
    ),
  );
}
