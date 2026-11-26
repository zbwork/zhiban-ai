import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
// The native preview plugin is supplied by the shared client.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

Future<Uint8List> captureRoundtablePng(
  GlobalKey root, {
  InAppWebViewController? previewController,
  Rect? previewBounds,
}) async {
  final layer =
      root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  const scale = 2.0;
  final image = await layer.toImage(pixelRatio: scale);
  ui.Image? composed;
  try {
    if (previewController != null) {
      final view = previewController;
      final screenshot = await view.takeScreenshot();
      if (screenshot == null || screenshot.isEmpty) {
        throw StateError('缺少实际 WebView 截图');
      }
      final codec = await ui.instantiateImageCodec(screenshot);
      final preview = (await codec.getNextFrame()).image;
      try {
        final bounds = previewBounds!.shift(-layer.localToGlobal(Offset.zero));
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImage(image, Offset.zero, Paint());
        canvas.scale(scale);
        canvas.clipRect(bounds);
        canvas.drawImageRect(
          preview,
          Rect.fromLTWH(
              0, 0, preview.width.toDouble(), preview.height.toDouble()),
          bounds,
          Paint()..filterQuality = FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        try {
          composed = await picture.toImage(image.width, image.height);
        } finally {
          picture.dispose();
        }
      } finally {
        preview.dispose();
        codec.dispose();
      }
    }
    final bytes =
        await (composed ?? image).toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('无法编码验收截图');
    return bytes.buffer.asUint8List();
  } finally {
    composed?.dispose();
    image.dispose();
  }
}
