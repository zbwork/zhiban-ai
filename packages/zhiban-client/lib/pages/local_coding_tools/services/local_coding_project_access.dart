import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';

typedef LocalCodingProjectDirectoryPicker = Future<String?> Function();
typedef LocalCodingProjectBookmarkCreator = Future<String> Function(
  String path
);

const MethodChannel _projectAccessChannel = MethodChannel(
  'cn.qkfintech.zhiban/local-coding-project',
);

Future<String?> pickLocalCodingProjectDirectory() {
  return getDirectoryPath(confirmButtonText: '选择项目');
}

Future<String> createLocalCodingProjectBookmark(String path) async {
  try {
    final bookmark = await _projectAccessChannel.invokeMethod<String>(
      'createProjectBookmark',
      {'path': path},
    );
    if (bookmark == null || bookmark.isEmpty) {
      throw const FormatException('empty bookmark');
    }
    final decoded = base64Decode(bookmark);
    if (decoded.isEmpty || decoded.length > 64 * 1024) {
      throw const FormatException('invalid bookmark size');
    }
    return bookmark;
  } on LocalCodingBridgeException {
    rethrow;
  } on PlatformException catch (error) {
    throw LocalCodingBridgeException(
      error.code.isEmpty ? 'project_permission_failed' : error.code,
      '无法获得项目目录权限，请重新选择',
    );
  } catch (_) {
    throw const LocalCodingBridgeException(
      'project_bookmark_invalid',
      '项目目录授权无效，请重新选择',
    );
  }
}
