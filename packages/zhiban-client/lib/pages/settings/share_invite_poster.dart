import 'package:zhiban_client/config/client_assets.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// F29 分享给朋友 — 邀请海报本地渲染与保存。
/// 与 F28 企业邀请海报同款 canvas 渲染管线（member_invite_poster.dart），
/// 不上传服务端；设计权威 docs/features/F29-friend-share-invite.md §1。

const shareInvitePosterWidth = 750;
const shareInvitePosterHeight = 1334;

class ShareInvitePosterSpec {
  const ShareInvitePosterSpec({required this.url, required this.inviteCode});

  final String url;

  /// 大写展示形态，如 ZBAI-8K29。
  final String inviteCode;
}

@visibleForTesting
Future<String?> Function(Uint8List bytes, String suggestedName)?
    debugSaveSharePosterOverride;

Future<Uint8List> renderShareInvitePoster(
  ShareInvitePosterSpec spec, {
  AssetBundle? assetBundle,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(
    shareInvitePosterWidth.toDouble(),
    shareInvitePosterHeight.toDouble(),
  );
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);

  final bundle = assetBundle ?? rootBundle;
  final logo = await _loadAssetImage(bundle, 'assets/app_icon.png');
  final mascot = await _loadAssetImage(
    bundle,
    'assets/images/share_invite_mascot.png',
  );
  try {
    _paintBrandHeader(canvas, logo);
    _paintCenteredText(
      canvas,
      '邀请好友使用知办AI',
      y: 196,
      maxWidth: 650,
      fontSize: 46,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF111827),
    );
    _paintCenteredText(
      canvas,
      '智能办公好搭档，效率从此加速',
      y: 276,
      maxWidth: 650,
      fontSize: 28,
      color: const Color(0xFF697386),
    );
    _paintContained(canvas, mascot, const Rect.fromLTWH(175, 330, 400, 250));
    _paintInviteCard(canvas, spec);
    _paintCenteredText(
      canvas,
      '或在手机应用商店搜索“知办AI”下载',
      y: 1226,
      maxWidth: 650,
      fontSize: 27,
      color: const Color(0xFF697386),
    );

    final image = await recorder.endRecording().toImage(
          shareInvitePosterWidth,
          shareInvitePosterHeight,
        );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('邀请海报 PNG 编码失败');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    logo.dispose();
    mascot.dispose();
  }
}

/// 把图片按 contain 规则绘制进目标区域（居中，保持长宽比）。
void _paintContained(Canvas canvas, ui.Image image, Rect target) {
  final scale = (target.width / image.width < target.height / image.height)
      ? target.width / image.width
      : target.height / image.height;
  final w = image.width * scale;
  final h = image.height * scale;
  final dst = Rect.fromLTWH(
    target.left + (target.width - w) / 2,
    target.top + (target.height - h) / 2,
    w,
    h,
  );
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    dst,
    Paint()..filterQuality = FilterQuality.high,
  );
}

Future<String?> saveShareInvitePoster(Uint8List bytes) async {
  const suggestedName = '知办AI-好友邀请海报.png';
  final override = debugSaveSharePosterOverride;
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
  final left = (shareInvitePosterWidth - totalWidth) / 2;
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

void _paintInviteCard(Canvas canvas, ShareInvitePosterSpec spec) {
  final cardRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(40, 608, 670, 580),
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

  const outerSize = 280.0;
  const qrSize = 244.0;
  const outerLeft = (shareInvitePosterWidth - outerSize) / 2;
  const outerTop = 644.0;
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

  _paintCenteredText(
    canvas,
    '扫码注册 体验智能办公',
    y: 948,
    maxWidth: 590,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    color: const Color(0xFF1D2129),
  );
  _paintCenteredText(
    canvas,
    '由我邀请，享受更快上手',
    y: 1002,
    maxWidth: 590,
    fontSize: 27,
    color: const Color(0xFF697386),
  );

  // 专属邀请码 chip
  final code = _textPainter(
    spec.inviteCode,
    fontSize: 40,
    fontWeight: FontWeight.w700,
    color: const Color(0xFF2563EB),
  );
  final label = _textPainter(
    '专属邀请码',
    fontSize: 25,
    color: const Color(0xFF697386),
  );
  const chipTop = 1056.0;
  const chipHeight = 112.0;
  final chipWidth =
      (code.width > label.width ? code.width : label.width) + 96;
  final chipRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(
      (shareInvitePosterWidth - chipWidth) / 2,
      chipTop,
      chipWidth,
      chipHeight,
    ),
    const Radius.circular(14),
  );
  canvas.drawRRect(chipRect, Paint()..color = Colors.white);
  canvas.drawRRect(
    chipRect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFDDE3EC),
  );
  label.paint(
    canvas,
    Offset((shareInvitePosterWidth - label.width) / 2, chipTop + 14),
  );
  code.paint(
    canvas,
    Offset((shareInvitePosterWidth - code.width) / 2, chipTop + 50),
  );
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
    Offset((shareInvitePosterWidth - painter.width) / 2, y),
  );
}

TextPainter _textPainter(
  String text, {
  required double fontSize,
  required Color color,
  FontWeight fontWeight = FontWeight.w400,
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
