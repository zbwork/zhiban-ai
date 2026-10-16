import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.isUpdateAvailable,
    this.title = '',
    this.releaseNotes = '',
    this.downloadUrl = '',
    this.appcastUrl = '',
    this.isForced = false,
  });

  final String currentVersion;
  final String currentBuildNumber;
  final String latestVersion;
  final String latestBuildNumber;
  final bool isUpdateAvailable;
  final String title;
  final String releaseNotes;
  final String downloadUrl;
  final String appcastUrl;
  final bool isForced;
}

class AppUpdateService {
  AppUpdateService({Dio? dio}) : _dio = dio ?? request;

  final Dio _dio;

  static String appcastUrl() {
    final platform = _currentPlatform();
    return '${AppConfig.apiUrl()}/app/appcast?platform=$platform&channel=stable';
  }

  Future<AppUpdateInfo?> fetchUpdateInfo() async {
    if (AppConfig.communityEdition) return null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final response = await _dio.get<dynamic>(
        '/app/update-info',
        queryParameters: <String, dynamic>{
          'platform': _currentPlatform(),
          'arch': _currentArch(),
          'channel': 'stable',
          'current_version': packageInfo.version,
          'current_build': packageInfo.buildNumber,
        },
        options: Options(extra: const {'silent': true}),
      );

      return parseUpdateInfoPayload(
        responseAsMap(response),
        currentVersion: packageInfo.version,
        currentBuildNumber: packageInfo.buildNumber,
      );
    } catch (_) {
      return null;
    }
  }
}

AppUpdateInfo parseUpdateInfoPayload(
  Map<String, dynamic> data, {
  required String currentVersion,
  required String currentBuildNumber,
}) {
  final latestRaw = data['latest'];
  final latest = latestRaw is Map
      ? latestRaw.cast<String, dynamic>()
      : const <String, dynamic>{};
  final updateAvailable = data['update_available'] == true && latest.isNotEmpty;

  return AppUpdateInfo(
    currentVersion: (data['current_version'] ?? currentVersion).toString(),
    currentBuildNumber:
        (data['current_build_number'] ?? currentBuildNumber).toString(),
    latestVersion: (latest['version'] ?? '').toString(),
    latestBuildNumber: (latest['build_number'] ?? '').toString(),
    isUpdateAvailable: updateAvailable,
    title: (latest['title'] ?? '').toString(),
    releaseNotes: (latest['release_notes'] ?? '').toString(),
    downloadUrl: (latest['download_url'] ?? '').toString(),
    appcastUrl: (latest['appcast_url'] ?? '').toString(),
    isForced: latest['is_forced'] == true,
  );
}

String _currentPlatform() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  return 'macos';
}

String _currentArch() {
  final value = Abi.current().toString().toLowerCase();
  if (value.contains('arm64')) return 'arm64';
  if (value.contains('x64') || value.contains('x86_64')) return 'x64';
  return 'universal';
}
