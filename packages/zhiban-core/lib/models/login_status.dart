/// 「我的 · 登录状态」页面用的数据模型。
///
/// 字段 surface 沿用历史 ai-office 版命名，是因为 settings_page.dart 调用面较大；
/// 实际数据来源已切到 agent-bus `/me/sessions`（见
/// [`docs/contracts/agent-bus-client-contract.md` §11.4]）。
/// agent-bus 一条 session 对应这里一个 [LoginStatusDevice]；后端暂不返回 UA 结构化解析、
/// 不区分 device/brand/model/system，这些字段用 UA 字符串本身或空值兜底。
/// 登录日志 (loginLogs) 留空，v1.0 不开放。
class LoginStatus {
  final LoginStatusDevice? currentDevice;
  final List<LoginStatusDevice> devices;
  final List<LoginStatusLog> loginLogs;

  const LoginStatus({
    required this.currentDevice,
    required this.devices,
    required this.loginLogs,
  });

  /// 从 agent-bus `GET /me/sessions` 响应构造:
  /// ```
  /// { items: [ { uuid, issuedAt, expiresAt, lastUsedAt, userAgent, ip,
  ///              actingAs, isCurrent } ] }
  /// ```
  /// 同时兼容老 ai-office schema `{currentDevice, devices, loginLogs}` (用于
  /// 解析本地缓存/兜底)。
  factory LoginStatus.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is List) {
      final devices = items
          .whereType<Map>()
          .map((m) => LoginStatusDevice.fromSession(m.cast<String, dynamic>()))
          .toList(growable: false);
      LoginStatusDevice? current;
      for (final d in devices) {
        if (d.isCurrent) {
          current = d;
          break;
        }
      }
      return LoginStatus(
        currentDevice: current,
        devices: devices,
        loginLogs: const [],
      );
    }
    return LoginStatus(
      currentDevice: json['currentDevice'] is Map<String, dynamic>
          ? LoginStatusDevice.fromJson(
              json['currentDevice'] as Map<String, dynamic>,
            )
          : null,
      devices: _list(json['devices'])
          .map((item) => LoginStatusDevice.fromJson(item))
          .toList(growable: false),
      loginLogs: _list(json['loginLogs'])
          .map((item) => LoginStatusLog.fromJson(item))
          .toList(growable: false),
    );
  }
}

class LoginStatusDevice {
  final String deviceId;
  final String deviceName;
  final String deviceModel;
  final String deviceBrand;
  final String deviceType;
  final String systemVersion;
  final String appVersion;
  final bool isActive;
  final bool isCurrent;
  final DateTime? lastActiveAt;
  final DateTime? updatedAt;

  const LoginStatusDevice({
    required this.deviceId,
    required this.deviceName,
    required this.deviceModel,
    required this.deviceBrand,
    required this.deviceType,
    required this.systemVersion,
    required this.appVersion,
    required this.isActive,
    required this.isCurrent,
    required this.lastActiveAt,
    required this.updatedAt,
  });

  factory LoginStatusDevice.fromJson(Map<String, dynamic> json) {
    return LoginStatusDevice(
      deviceId: (json['deviceId'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? '').toString(),
      deviceModel: (json['deviceModel'] ?? '').toString(),
      deviceBrand: (json['deviceBrand'] ?? '').toString(),
      deviceType: (json['deviceType'] ?? '').toString(),
      systemVersion: (json['systemVersion'] ?? '').toString(),
      appVersion: (json['appVersion'] ?? '').toString(),
      isActive: json['isActive'] == true,
      isCurrent: json['isCurrent'] == true,
      lastActiveAt: _date(json['lastActiveAt']),
      updatedAt: _date(json['updatedAt']),
    );
  }

  /// 从 agent-bus session 行 (`MySessionSummary`) 构造。
  ///
  /// 优先用登录时客户端结构化上报的 `device*` 字段（§10.6）；旧 session 行没有
  /// 这些字段（登录时客户端未上报）才回退到 UA 字符串启发式解析。
  factory LoginStatusDevice.fromSession(Map<String, dynamic> json) {
    final ua = (json['userAgent'] ?? '').toString();
    final ip = (json['ip'] ?? '').toString();
    final reportedType = (json['deviceType'] ?? '').toString();
    final reportedBrand = (json['deviceBrand'] ?? '').toString();
    final reportedModel = (json['deviceModel'] ?? '').toString();
    final reportedSystemVersion = (json['deviceSystemVersion'] ?? '').toString();
    final reportedAppVersion = (json['deviceAppVersion'] ?? '').toString();
    final hasReportedDevice = reportedType.isNotEmpty ||
        reportedBrand.isNotEmpty ||
        reportedModel.isNotEmpty ||
        reportedSystemVersion.isNotEmpty;
    final parsed = hasReportedDevice ? null : _parseUserAgent(ua);
    final brand = hasReportedDevice ? reportedBrand : (parsed?.brand ?? '');
    final model = hasReportedDevice ? reportedModel : (parsed?.model ?? '');
    final type = hasReportedDevice ? reportedType : (parsed?.type ?? '');
    final systemVersion =
        hasReportedDevice ? reportedSystemVersion : (parsed?.systemVersion ?? '');
    final appVersion =
        hasReportedDevice ? reportedAppVersion : (parsed?.appVersion ?? '');
    final lastUsed = _date(json['lastUsedAt']);
    final issuedAt = _date(json['issuedAt']);
    // deviceName 展示规则: 优先"品牌 + 型号 + 系统版本"; 不行就 UA 原文; 再不行就 IP。
    final composedName =
        [brand, model, systemVersion].where((s) => s.isNotEmpty).join(' · ');
    final name = composedName.isNotEmpty
        ? composedName
        : (ua.isNotEmpty ? ua : (ip.isNotEmpty ? 'IP $ip' : '未知设备'));
    return LoginStatusDevice(
      deviceId: (json['uuid'] ?? '').toString(),
      deviceName: name,
      deviceModel: model,
      deviceBrand: brand,
      deviceType: type,
      systemVersion: systemVersion,
      appVersion: appVersion,
      isActive: true,
      isCurrent: json['isCurrent'] == true,
      lastActiveAt: lastUsed,
      updatedAt: lastUsed ?? issuedAt,
    );
  }

  String get displayName {
    if (deviceName.trim().isNotEmpty) return deviceName.trim();
    if (deviceModel.trim().isNotEmpty) return deviceModel.trim();
    if (deviceBrand.trim().isNotEmpty) return deviceBrand.trim();
    if (deviceId.trim().isNotEmpty) return '设备 ${deviceId.trim()}';
    return '未知设备';
  }

  DateTime? get displayTime => lastActiveAt ?? updatedAt;
}

class LoginStatusLog {
  final String loginType;
  final String loginIp;
  final String deviceId;
  final String deviceName;
  final String deviceModel;
  final String deviceBrand;
  final String appVersion;
  final DateTime? createdAt;

  const LoginStatusLog({
    required this.loginType,
    required this.loginIp,
    required this.deviceId,
    required this.deviceName,
    required this.deviceModel,
    required this.deviceBrand,
    required this.appVersion,
    required this.createdAt,
  });

  factory LoginStatusLog.fromJson(Map<String, dynamic> json) {
    return LoginStatusLog(
      loginType: (json['loginType'] ?? '').toString(),
      loginIp: (json['loginIp'] ?? '').toString(),
      deviceId: (json['deviceId'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? '').toString(),
      deviceModel: (json['deviceModel'] ?? '').toString(),
      deviceBrand: (json['deviceBrand'] ?? '').toString(),
      appVersion: (json['appVersion'] ?? '').toString(),
      createdAt: _date(json['createdAt']),
    );
  }

  String get displayDevice {
    if (deviceName.trim().isNotEmpty) return deviceName.trim();
    if (deviceModel.trim().isNotEmpty) return deviceModel.trim();
    if (deviceId.trim().isNotEmpty) return '设备 ${deviceId.trim()}';
    return '未知设备';
  }
}

List<Map<String, dynamic>> _list(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

DateTime? _date(Object? value) {
  final raw = (value ?? '').toString();
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

/// UA 字符串简单结构化解析。
///
/// agent-bus 只存 UA 原文 (登录请求 `User-Agent`); 这里做最朴素的关键字识别,
/// 仅为「我的 · 登录状态」UI 展示更友好。识别失败一律回退到 UA 原文展示。
class _ParsedUA {
  final String brand;
  final String model;
  final String type;
  final String systemVersion;
  final String appVersion;

  const _ParsedUA({
    this.brand = '',
    this.model = '',
    this.type = '',
    this.systemVersion = '',
    this.appVersion = '',
  });

  String get displayName {
    final parts = <String>[];
    if (brand.isNotEmpty) parts.add(brand);
    if (model.isNotEmpty) parts.add(model);
    if (systemVersion.isNotEmpty) parts.add(systemVersion);
    return parts.join(' · ');
  }
}

_ParsedUA _parseUserAgent(String ua) {
  if (ua.isEmpty) return const _ParsedUA();
  final lower = ua.toLowerCase();
  String brand = '';
  String type = '';
  String systemVersion = '';
  if (lower.contains('iphone')) {
    brand = 'iPhone';
    type = 'mobile';
  } else if (lower.contains('ipad')) {
    brand = 'iPad';
    type = 'tablet';
  } else if (lower.contains('android')) {
    brand = 'Android';
    type = 'mobile';
    final m = RegExp(r'Android\s+([\d.]+)').firstMatch(ua);
    if (m != null) systemVersion = 'Android ${m.group(1)}';
  } else if (lower.contains('macintosh') || lower.contains('mac os')) {
    brand = 'Mac';
    type = 'desktop';
  } else if (lower.contains('windows')) {
    brand = 'Windows';
    type = 'desktop';
  } else if (lower.contains('linux')) {
    brand = 'Linux';
    type = 'desktop';
  }
  if (systemVersion.isEmpty) {
    final ios = RegExp(r'OS\s+([\d_]+)\s+like\s+Mac').firstMatch(ua);
    if (ios != null) {
      systemVersion = 'iOS ${ios.group(1)!.replaceAll('_', '.')}';
    }
  }
  final appMatch =
      RegExp(r'(ZhibanApp|Nexwork)/([\w\d.+-]+)', caseSensitive: false).firstMatch(ua);
  final appVersion = appMatch != null ? appMatch.group(2)! : '';
  return _ParsedUA(
    brand: brand,
    model: '',
    type: type,
    systemVersion: systemVersion,
    appVersion: appVersion,
  );
}
