// 登录时随请求体上报的结构化设备信息 (agent-bus-client-contract.md §10.6)。
//
// 只影响 `login_sessions.device_*` 的展示字段，不碰 HTTP `User-Agent` 头——
// 改 UA 头在这个环境下已验证过会破坏网络连通性，禁止复用该思路。
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:zhiban_client/config/app_config.dart';

class LoginDeviceInfo {
  const LoginDeviceInfo({
    this.type = '',
    this.brand = '',
    this.model = '',
    this.systemVersion = '',
    this.appVersion = '',
    this.fingerprint = '',
  });

  final String type;
  final String brand;
  final String model;
  final String systemVersion;
  final String appVersion;
  // 稳定设备标识, 见 collectDeviceFingerprint()。
  final String fingerprint;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (type.isNotEmpty) 'type': type,
        if (brand.isNotEmpty) 'brand': brand,
        if (model.isNotEmpty) 'model': model,
        if (systemVersion.isNotEmpty) 'systemVersion': systemVersion,
        if (appVersion.isNotEmpty) 'appVersion': appVersion,
        if (fingerprint.isNotEmpty) 'deviceFingerprint': fingerprint,
      };
}

/// 本地持久化的稳定设备标识: 首次生成后写 SharedPreferences 永久保留,
/// 不随重新登录 / 退出登录 / 切账号变化(session_service.clearSessionStorage
/// 不清这个 key)。后端登录时用它识别"同一台设备"，顶掉该设备上的旧 session。
Future<String> collectDeviceFingerprint() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(AppConfig.storageDeviceFingerprintKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await prefs.setString(AppConfig.storageDeviceFingerprintKey, generated);
    return generated;
  } catch (_) {
    // 存取失败就不带指纹, 后端按旧客户端处理(不去重), 不影响登录本身。
    return '';
  }
}

Future<LoginDeviceInfo> collectLoginDeviceInfo() async {
  final fingerprint = await collectDeviceFingerprint();
  var appVersion = '';
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final build = packageInfo.buildNumber.trim();
    appVersion =
        build.isEmpty ? packageInfo.version : '${packageInfo.version}+$build';
  } catch (_) {
    // 拿不到就不传，后端/展示端按空处理。
  }
  try {
    final deviceInfo = await DeviceInfoPlugin().deviceInfo;
    if (deviceInfo is MacOsDeviceInfo) {
      return LoginDeviceInfo(
        type: 'macOS',
        brand: 'Apple',
        model: deviceInfo.modelName,
        systemVersion: deviceInfo.osRelease,
        appVersion: appVersion,
        fingerprint: fingerprint,
      );
    }
    if (deviceInfo is WindowsDeviceInfo) {
      return LoginDeviceInfo(
        type: 'Windows',
        model: deviceInfo.productName,
        systemVersion: deviceInfo.displayVersion,
        appVersion: appVersion,
        fingerprint: fingerprint,
      );
    }
    if (deviceInfo is LinuxDeviceInfo) {
      return LoginDeviceInfo(
        type: 'Linux',
        model: deviceInfo.prettyName,
        systemVersion: deviceInfo.version ?? '',
        appVersion: appVersion,
        fingerprint: fingerprint,
      );
    }
    if (deviceInfo is AndroidDeviceInfo) {
      return LoginDeviceInfo(
        type: 'Android',
        brand: deviceInfo.brand,
        model: deviceInfo.model,
        systemVersion: deviceInfo.version.release,
        appVersion: appVersion,
        fingerprint: fingerprint,
      );
    }
    if (deviceInfo is IosDeviceInfo) {
      return LoginDeviceInfo(
        type: 'iOS',
        brand: 'Apple',
        model: deviceInfo.modelName,
        systemVersion: deviceInfo.systemVersion,
        appVersion: appVersion,
        fingerprint: fingerprint,
      );
    }
    if (deviceInfo is WebBrowserInfo) {
      return LoginDeviceInfo(
        type: 'Web',
        brand: deviceInfo.browserName.name,
        systemVersion: deviceInfo.appVersion ?? '',
        appVersion: appVersion,
        fingerprint: fingerprint,
      );
    }
  } catch (_) {
    // 拿不到设备信息就只带 appVersion，其余留空。
  }
  return LoginDeviceInfo(appVersion: appVersion, fingerprint: fingerprint);
}
