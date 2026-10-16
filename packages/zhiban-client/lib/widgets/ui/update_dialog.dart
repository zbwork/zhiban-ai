import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/app_update_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/services/android_update_service.dart';
import 'package:zhiban_ui/widgets/ui_tap_surface.dart';
import 'package:url_launcher/url_launcher.dart';

/// App Store 详情页固定链接（App ID 不随版本变化）；后端 client_versions 记录
/// 的 download_url 对 iOS 是可选字段（发布校验不强制要求），管理员没填时就用
/// 这个兜底，避免"前往 App Store"按钮点了没反应。
const _iosAppStoreUrl =
    'https://apps.apple.com/cn/app/%E7%9F%A5%E5%8A%9Eai/id6770980462';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  AppUpdateInfo info,
) {
  if (Platform.isAndroid) {
    return showAndroidUpdateAvailableDialog(context, info);
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: !info.isForced,
    builder: (_) => _UpdateDialog(info: info),
  );
}

class _UpdateDialogLayout extends StatelessWidget {
  const _UpdateDialogLayout({required this.info, required this.actions});
  final AppUpdateInfo info;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      backgroundColor: Colors.white,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1E101828),
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF4C8DFF), Color(0xFF165DFF)],
                    ),
                  ),
                  child: const Icon(
                    CupertinoIcons.arrow_2_circlepath,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '发现新版本',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF172033),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEF2FF),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'v${info.latestVersion}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF165DFF),
                    ),
                  ),
                ),
              ],
            ),
            if (info.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '更新内容',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF98A2B3),
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    info.releaseNotes,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: Color(0xFF475467),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            actions,
          ],
        ),
      ),
    );
  }
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.info});
  final AppUpdateInfo info;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !info.isForced,
        child: _UpdateDialogLayout(
          info: info,
          actions: Row(children: [
            if (!info.isForced) ...[
              Expanded(
                  child: _DialogButton(
                      label: '稍后再说',
                      secondary: true,
                      onTap: () => Navigator.of(context).pop())),
              const SizedBox(width: 12),
            ],
            Expanded(
                child: _DialogButton(
              label: Platform.isIOS ? '前往 App Store' : '立即更新',
              onTap: () {
                final url = info.downloadUrl.isNotEmpty
                    ? info.downloadUrl
                    : (Platform.isIOS ? _iosAppStoreUrl : '');
                final uri = Uri.tryParse(url);
                if (uri != null && url.isNotEmpty) {
                  unawaited(
                      launchUrl(uri, mode: LaunchMode.externalApplication));
                }
                if (!info.isForced) Navigator.of(context).pop();
              },
            )),
          ]),
        ),
      );
}

bool _androidUpdateDialogOpen = false;

Future<void> showAndroidUpdateAvailableDialog(
    BuildContext context, AppUpdateInfo info) async {
  if (_androidUpdateDialogOpen) return;
  _androidUpdateDialogOpen = true;
  try {
    await showDialog<void>(
        context: context,
        barrierDismissible: !info.isForced,
        builder: (_) => AndroidUpdateDialog(info: info));
  } finally {
    _androidUpdateDialogOpen = false;
  }
}

/// Android entrypoint: download state belongs to the app provider, not this route.
class AndroidUpdateDialog extends ConsumerStatefulWidget {
  const AndroidUpdateDialog({super.key, required this.info});
  final AppUpdateInfo info;

  @override
  ConsumerState<AndroidUpdateDialog> createState() =>
      _AndroidUpdateDialogState();
}

class _AndroidUpdateDialogState extends ConsumerState<AndroidUpdateDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(androidUpdateProvider.notifier).refresh());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(androidUpdateProvider);
    final controller = ref.read(androidUpdateProvider.notifier);
    final download = state.download;
    final info = download.info ?? widget.info;
    final forced = widget.info.isForced || info.isForced;
    final active = download.isActive;
    final ready = download.status == AndroidDownloadStatus.ready;
    final failed = download.status == AndroidDownloadStatus.failed;
    final message = state.notice ??
        (state.stalled
            ? '暂时没有新进度，下载任务仍保留'
            : download.hasTask
                ? download.message
                : null);
    final actionLabel = ready
        ? '立即安装'
        : failed
            ? '重试下载'
            : '立即下载';
    return PopScope(
      canPop: !forced,
      child: _UpdateDialogLayout(
        info: info,
        actions: Column(mainAxisSize: MainAxisSize.min, children: [
          if (active || ready) ...[
            _DownloadProgress(
                progress: ready ? 1 : download.progress,
                label: ready ? '安装包已下载完成' : state.label),
            const SizedBox(height: 12),
          ],
          if (message != null && message.isNotEmpty) ...[
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: failed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
          ],
          if (!active || !forced)
            Row(children: [
              if (!forced) ...[
                Expanded(
                    child: _DialogButton(
                  label: download.hasTask ? '最小化' : '稍后再说',
                  secondary: true,
                  onTap: () => Navigator.of(context).pop(),
                )),
                if (!active) const SizedBox(width: 12),
              ],
              if (!active)
                Expanded(
                    child: _DialogButton(
                  label: state.busy ? '请稍候…' : actionLabel,
                  onTap: state.busy
                      ? null
                      : () {
                          if (ready) {
                            unawaited(controller.install());
                          } else if (failed) {
                            unawaited(controller.retry());
                          } else {
                            unawaited(controller.start(info));
                          }
                        },
                )),
            ]),
        ]),
      ),
    );
  }
}

/// Minimized progress surface shown by the mobile shell above its tab bar.
class AndroidUpdateProgressEntry extends ConsumerWidget {
  const AndroidUpdateProgressEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(androidUpdateProvider);
    final info = state.download.info;
    if (info == null || info.isForced) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return UiTapSurface(
      onTap: () => showAndroidUpdateAvailableDialog(context, info),
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          if (state.download.isActive)
            const SizedBox(
                width: 18, height: 18, child: CupertinoActivityIndicator())
          else
            Icon(
                state.download.status == AndroidDownloadStatus.ready
                    ? CupertinoIcons.arrow_down_doc
                    : CupertinoIcons.exclamationmark_circle,
                size: 20,
                color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(state.label,
                  maxLines: 2,
                  style: TextStyle(fontSize: 13, color: scheme.onSurface))),
          const SizedBox(width: 8),
          Icon(CupertinoIcons.chevron_up,
              size: 14, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.progress, required this.label});

  final double? progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: const Color(0xFFEEF1F5),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF165DFF)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Color(0xFF5D6B82)),
        ),
      ],
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.onTap,
    this.secondary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    return UiTapSurface(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      color: secondary ? const Color(0xFFF2F4F7) : const Color(0xFF165DFF),
      child: SizedBox(
        height: 46,
        child: Center(
            child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: secondary ? const Color(0xFF344054) : Colors.white,
          ),
        )),
      ),
    );
  }
}
