import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../model_service/models/ai_provider_config.dart';
import 'creator_expert_workflow.dart';
import 'creator_remote_media.dart';

const _maxPortraitBytes = 12 * 1024 * 1024;

const _seatViews = [
  'near-left of the table; show mostly their back and their right side, '
      'seated facing diagonally away from the camera toward the upper right',
  'far-left of the table; three-quarter front view facing inward to the lower right',
  'far-right of the table; three-quarter front view facing inward to the lower left',
  'near-right of the table; show mostly their back and their left side, '
      'seated facing diagonally away from the camera toward the upper left',
  'far center of the table; three-quarter overhead front view facing the camera side',
  'left end of the table; right-facing side profile with shoulders toward the table',
  'right end of the table; left-facing side profile with shoulders toward the table',
  'near center of the table; rear view with both shoulders facing away from the camera',
];

const _foregroundSeats = {0, 3, 7};

String creatorPortraitKey(String creatorId, String avatar, int slot) {
  final uri = Uri.tryParse(avatar);
  final image = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
      ? '${uri.origin}${uri.path}'
      : avatar;
  return sha256
      .convert(utf8.encode(jsonEncode([1, creatorId, image, slot])))
      .toString();
}

Uri creatorPortraitEndpoint(String configured) {
  final uri = Uri.tryParse(configured.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
    throw const CreatorWorkflowException('图片服务地址须使用 HTTPS，本机服务可使用 HTTP。');
  }
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return uri.replace(
    path: path.endsWith('/images/edits')
        ? path
        : '${path.isEmpty ? '/v1' : path}/images/edits',
  );
}

class CreatorSeatPortraitService {
  CreatorSeatPortraitService({
    Dio? transport,
    CreatorRemoteMedia Function()? mediaFactory,
  })  : _transport = transport ??
            Dio(BaseOptions(connectTimeout: const Duration(seconds: 20))),
        _mediaFactory = mediaFactory ?? CreatorRemoteMedia.new;

  final Dio _transport;
  final CreatorRemoteMedia Function() _mediaFactory;

  File _file(Directory root, String creatorId, String avatar, int slot) => File(
      '${root.path}/seat-portraits/${creatorPortraitKey(creatorId, avatar, slot)}.png');

  Future<File?> load(
      Directory root, String creatorId, String avatar, int slot) async {
    final file = _file(root, creatorId, avatar, slot);
    return await file.exists() ? file : null;
  }

  Future<File> generate({
    required Directory root,
    required String creatorId,
    required String avatar,
    required int slot,
    required AiProviderConfig provider,
    required String model,
    required String key,
    required CancelToken cancel,
  }) async {
    if (slot < 0 || slot >= _seatViews.length) {
      throw const CreatorWorkflowException('当前席位不可用。');
    }
    final endpoint = creatorPortraitEndpoint(
        provider.imageEditBaseUrl.trim().isEmpty
            ? provider.baseUrl
            : provider.imageEditBaseUrl);
    if (key.trim().isEmpty) {
      throw const CreatorWorkflowException('请先给该图片服务配置 API Key。');
    }
    final media = _mediaFactory();
    final Uint8List avatarPng;
    try {
      final image = await media.readImage(avatar, cancel);
      avatarPng = await _encodeAvatar(image.bytes);
    } on DioException {
      throw const CreatorWorkflowException('未能读取博主头像，请检查网络后重试。');
    } on FormatException {
      throw const CreatorWorkflowException('该博主的头像暂时无法读取。');
    } finally {
      media.close();
    }
    final outfitFraming = _foregroundSeats.contains(slot)
        ? 'Show the entire seated pose, including knees and shoes. '
            'Keep the head, arms and feet uncropped.'
        : 'Show the seated upper body from the waist up, including both elbows.';
    final Uint8List generated;
    try {
      final result = await _transport.post<ResponseBody>(
        endpoint.toString(),
        data: FormData.fromMap({
          'model': model,
          'image[]': MultipartFile.fromBytes(avatarPng,
              filename: 'avatar.png',
              contentType: DioMediaType('image', 'png')),
          'prompt': 'Create one stylized, natural-proportioned AI character based on the '
              'reference portrait. The viewer looks down at the scene from a fixed '
              'wide-angle camera above a conference table. Seat position: ${_seatViews[slot]}. '
              'Turn the shoulders, torso, and gaze toward the center of the table. '
              'Place the forearms in front at a natural tabletop height. '
              '$outfitFraming '
              'Soft window lighting and realistic clothing folds. Show only the character '
              'on a transparent background. Do not draw furniture, props, or text.',
          'background': 'transparent',
          'output_format': 'png',
          'size': '1024x1024',
        }),
        cancelToken: cancel,
        options: Options(
          headers: {
            for (final entry in provider.customHeaders.entries)
              if (entry.key.toLowerCase() != 'authorization')
                entry.key: entry.value,
            'Authorization': 'Bearer $key',
          },
          followRedirects: false,
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 3),
        ),
      );
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in result.data!.stream) {
        if (buffer.length + chunk.length > 2 * _maxPortraitBytes) {
          throw const FormatException('image response exceeds limit');
        }
        buffer.add(chunk);
      }
      final response = jsonDecode(utf8.decode(buffer.takeBytes())) as Map;
      final images = response['data'] as List?;
      final raw = (images?.firstOrNull as Map?)?['b64_json'];
      if (raw is! String || raw.isEmpty) {
        throw const FormatException('expected base64 image');
      }
      generated = await _trimPortrait(base64Decode(raw));
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw CreatorWorkflowException(switch (status) {
        401 || 403 => '图片服务拒绝了请求，请检查密钥和模型权限。',
        404 => '图片编辑接口不可用，请检查服务地址。',
        429 => '图片服务暂时限流，请稍后重试。',
        _ => cancel.isCancelled ? '已取消生成。' : '图片服务未能生成形象，请检查模型后重试。',
      });
    } on FormatException {
      throw const CreatorWorkflowException('图片模型没有返回可用的透明 PNG。');
    } on TypeError {
      throw const CreatorWorkflowException('图片模型没有返回可用的透明 PNG。');
    } on StateError {
      throw const CreatorWorkflowException('图片模型没有返回可用的透明 PNG。');
    }
    if (cancel.isCancelled) throw const CreatorWorkflowException('已取消生成。');
    final target = _file(root, creatorId, avatar, slot);
    await target.parent.create(recursive: true);
    final staging = await target.parent.createTemp('.portrait-');
    try {
      final temporary = await File('${staging.path}/portrait.png')
          .writeAsBytes(generated, flush: true);
      if (cancel.isCancelled) throw const CreatorWorkflowException('已取消生成。');
      return await temporary.rename(target.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<Uint8List> _encodeAvatar(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 512);
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> _trimPortrait(Uint8List png) async {
    if (png.length < 33 ||
        png.length > _maxPortraitBytes ||
        png[0] != 137 ||
        png[1] != 80 ||
        png[2] != 78 ||
        png[3] != 71) {
      throw const FormatException('invalid PNG');
    }
    final header = ByteData.sublistView(png);
    final width = header.getUint32(16);
    final height = header.getUint32(20);
    if (width == 0 || height == 0 || width > 2048 || height > 2048) {
      throw const FormatException('invalid PNG dimensions');
    }
    final codec = await ui.instantiateImageCodec(png);
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        final pixels =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        var left = width, top = height, right = -1, bottom = -1;
        var hasTransparent = false;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            if (pixels.getUint8((y * width + x) * 4 + 3) < 16) {
              hasTransparent = true;
              continue;
            }
            if (x < left) left = x;
            if (x > right) right = x;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
        if (!hasTransparent || right < left || bottom < top) {
          throw const FormatException('expected a cutout');
        }
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImage(
          image,
          ui.Offset(-left.toDouble(), -top.toDouble()),
          ui.Paint(),
        );
        final picture = recorder.endRecording();
        try {
          final trimmed =
              await picture.toImage(right - left + 1, bottom - top + 1);
          try {
            return (await trimmed.toByteData(format: ui.ImageByteFormat.png))!
                .buffer
                .asUint8List();
          } finally {
            trimmed.dispose();
          }
        } finally {
          picture.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
