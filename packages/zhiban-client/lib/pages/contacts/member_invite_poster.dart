import 'package:zhiban_client/config/client_assets.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

const memberInvitePosterWidth = 750;
const memberInvitePosterHeight = 1334;

class MemberInvitePosterSpec {
  const MemberInvitePosterSpec({
    required this.url,
    required this.tenantName,
    required this.inviterName,
    required this.expiresAt,
  });

  final String url;
  final String tenantName;
  final String inviterName;
  final DateTime? expiresAt;
}

@visibleForTesting
Future<void> Function(Uint8List bytes)? debugCopyInvitePosterOverride;

@visibleForTesting
Future<String?> Function(Uint8List bytes, String suggestedName)?
    debugSaveInvitePosterOverride;

Future<Uint8List> renderMemberInvitePoster(
  MemberInvitePosterSpec spec, {
  AssetBundle? assetBundle,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(
    memberInvitePosterWidth.toDouble(),
    memberInvitePosterHeight.toDouble(),
  );
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);

  final logo = await _loadAssetImage(
    assetBundle ?? rootBundle,
    'assets/app_icon.png',
  );
  try {
    _paintBrandHeader(canvas, logo);
    _paintInviter(canvas, spec.inviterName);
    _paintInviteCard(canvas, spec);
    _paintCenteredText(
      canvas,
      '请在手机应用商店中搜索“知办AI”并下载',
      y: 1148,
      maxWidth: 650,
      fontSize: 27,
      color: const Color(0xFF697386),
    );

    final image = await recorder.endRecording().toImage(
          memberInvitePosterWidth,
          memberInvitePosterHeight,
        );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('企业邀请海报 PNG 编码失败');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    logo.dispose();
  }
}

Future<void> copyMemberInvitePoster(Uint8List bytes) async {
  final override = debugCopyInvitePosterOverride;
  if (override != null) {
    await override(bytes);
    return;
  }
  if (Platform.isLinux) {
    throw UnsupportedError('当前 Linux 版本暂不支持复制图片');
  }
  await Pasteboard.writeImage(bytes);
}

Future<String?> saveMemberInvitePoster(
  Uint8List bytes, {
  required String tenantName,
}) async {
  final suggestedName = '${_safeFileName(tenantName)}-企业邀请二维码.png';
  final override = debugSaveInvitePosterOverride;
  if (override != null) return override(bytes, suggestedName);

  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      confirmButtonText: '保存',
    );
    if (location == null) return null;
    await XFile.fromData(
      bytes,
      mimeType: 'image/png',
      name: suggestedName,
    ).saveTo(location.path);
    return location.path;
  }

  final directory = await getApplicationDocumentsDirectory();
  final path = '${directory.path}${Platform.pathSeparator}$suggestedName';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

Future<ui.Image> _loadAssetImage(AssetBundle bundle, String asset) async {
  final data = await bundle.load(ClientAssets.path(asset));
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

void _paintBrandHeader(Canvas canvas, ui.Image logo) {
  const logoSize = 76.0;
  final title = _textPainter(
    '知办AI',
    fontSize: 42,
    fontWeight: FontWeight.w700,
    color: const Color(0xFF111827),
  );
  final totalWidth = logoSize + 18 + title.width;
  final left = (memberInvitePosterWidth - totalWidth) / 2;
  final logoRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(left, 64, logoSize, logoSize),
    const Radius.circular(18),
  );
  canvas.save();
  canvas.clipRRect(logoRect);
  canvas.drawImageRect(
    logo,
    Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
    logoRect.outerRect,
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
  title.paint(canvas, Offset(left + logoSize + 18, 77));
}

void _paintInviter(Canvas canvas, String rawName) {
  final name = rawName.trim().isEmpty ? '企业管理员' : rawName.trim();
  final text = _textPainter(
    '$name 邀请你加入',
    fontSize: 30,
    fontWeight: FontWeight.w500,
    color: const Color(0xFF1D2129),
  );
  const avatarSize = 52.0;
  final totalWidth = avatarSize + 16 + text.width;
  final left = (memberInvitePosterWidth - totalWidth) / 2;
  final avatarRect = Rect.fromLTWH(left, 206, avatarSize, avatarSize);
  canvas.drawCircle(
    avatarRect.center,
    avatarSize / 2,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF35D3D8), Color(0xFF2563EB)],
      ).createShader(avatarRect),
  );
  final initial = _textPainter(
    _firstCharacter(name),
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: Colors.white,
  );
  initial.paint(
    canvas,
    Offset(
      avatarRect.center.dx - initial.width / 2,
      avatarRect.center.dy - initial.height / 2,
    ),
  );
  text.paint(canvas, Offset(left + avatarSize + 16, 214));
}

void _paintInviteCard(Canvas canvas, MemberInvitePosterSpec spec) {
  final cardRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(40, 300, 670, 720),
    const Radius.circular(18),
  );
  canvas.drawRRect(
    cardRect,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF0F7FF), Color(0xFFFFFFFF)],
      ).createShader(cardRect.outerRect),
  );
  canvas.drawRRect(
    cardRect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFD9E1EA),
  );

  _paintCenteredText(
    canvas,
    '仅支持区号为 +86 的手机号加入以下企业',
    y: 392,
    maxWidth: 590,
    fontSize: 27,
    color: const Color(0xFF697386),
  );
  _paintCenteredText(
    canvas,
    spec.tenantName,
    y: 452,
    maxWidth: 590,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    color: const Color(0xFF1D2129),
    maxLines: 2,
  );

  const outerSize = 312.0;
  const qrSize = 276.0;
  const outerLeft = (memberInvitePosterWidth - outerSize) / 2;
  const outerTop = 548.0;
  final qrOuter = RRect.fromRectAndRadius(
    const Rect.fromLTWH(outerLeft, outerTop, outerSize, outerSize),
    const Radius.circular(12),
  );
  canvas.drawRRect(qrOuter, Paint()..color = Colors.white);
  canvas.drawRRect(
    qrOuter,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFDDE3EC),
  );
  canvas.save();
  canvas.translate(outerLeft + 18, outerTop + 18);
  QrPainter(
    data: spec.url,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.H,
    gapless: true,
  ).paint(canvas, const Size(qrSize, qrSize));
  canvas.restore();

  final badgeRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(
      (memberInvitePosterWidth - 48) / 2,
      outerTop + (outerSize - 48) / 2,
      48,
      48,
    ),
    const Radius.circular(8),
  );
  canvas.drawRRect(badgeRect, Paint()..color = Colors.white);
  final badgeInner = badgeRect.deflate(4);
  canvas.drawRRect(badgeInner, Paint()..color = const Color(0xFF2F80ED));
  final badgeText = _textPainter(
    _firstCharacter(spec.tenantName),
    fontSize: 21,
    fontWeight: FontWeight.w700,
    color: Colors.white,
  );
  badgeText.paint(
    canvas,
    Offset(
      badgeInner.center.dx - badgeText.width / 2,
      badgeInner.center.dy - badgeText.height / 2,
    ),
  );

  final expiresLabel = _expiresLabel(spec.expiresAt);
  if (expiresLabel.isNotEmpty) {
    _paintCenteredText(
      canvas,
      '二维码失效时间：$expiresLabel',
      y: 922,
      maxWidth: 600,
      fontSize: 25,
      color: const Color(0xFF98A2B3),
    );
  }
}

void _paintCenteredText(
  Canvas canvas,
  String text, {
  required double y,
  required double maxWidth,
  required double fontSize,
  required Color color,
  FontWeight fontWeight = FontWeight.w400,
  int? maxLines,
}) {
  final painter = _textPainter(
    text,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    textAlign: TextAlign.center,
    maxLines: maxLines,
    maxWidth: maxWidth,
  );
  painter.paint(
    canvas,
    Offset((memberInvitePosterWidth - painter.width) / 2, y),
  );
}

TextPainter _textPainter(
  String text, {
  required double fontSize,
  required FontWeight fontWeight,
  required Color color,
  TextAlign textAlign = TextAlign.left,
  int? maxLines,
  double maxWidth = double.infinity,
}) {
  return TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'packages/zhiban_ui/HarmonyOS Sans SC',
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: 1.25,
      ),
    ),
    textAlign: textAlign,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: maxWidth);
}

String _expiresLabel(DateTime? expiresAt) {
  if (expiresAt == null) return '';
  final local = expiresAt.toLocal();
  return '${local.year}年${local.month}月${local.day}日';
}

String _firstCharacter(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '企';
  return String.fromCharCode(trimmed.runes.first);
}

String _safeFileName(String value) {
  final sanitized = value
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ');
  return sanitized.isEmpty ? '知办AI' : sanitized;
}
