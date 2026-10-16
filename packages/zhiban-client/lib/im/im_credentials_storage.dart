import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// F09 IM 凭证 + device_id 的本地安全持久化。
///
/// - `device_id`：终端首次启动随机生成（UUID v4），与本设备绑定，跨重启不变。
///   随 `POST /im/credentials` 上送服务端做 refresh_token 绑定校验。
/// - `im_refresh_token`：服务端签发的 IM 长 TTL（默认 7d）刷新凭证。移动端和非 macOS
///   桌面端仅在 secure storage 中持久化；macOS 为避免正式包/本地包启动时触发
///   Keychain ACL 密码弹框，不持久化 refresh token，启动时通过已有登录态重新签发。
///   **禁止**把 refresh token 写入 SharedPreferences / 文件 / 日志。
/// - 注销 / 切账号时调用 [clearAll] 一并清掉。
///
/// 不持久化短 TTL IM 连接 token：每次进程启动重新走 issue 拿新 token，
/// 既能避开 token 过期场景，也避免明文 token 被快照备份带走。
class IMCredentialsStorage {
  IMCredentialsStorage({FlutterSecureStorage? storage, Uuid? uuid})
      : _delegate = _buildDelegate(storage),
        _uuid = uuid ?? const Uuid();

  static const _deviceIdKey = 'im.device_id';
  static const _refreshTokenKey = 'im.refresh_token';
  static const _refreshExpiresAtKey = 'im.refresh_expires_at';

  final _IMCredentialsStorageDelegate _delegate;
  final Uuid _uuid;

  /// 拿到稳定的 device_id；首次调用会生成并写入。
  Future<String> getOrCreateDeviceId() => _delegate.getOrCreateDeviceId(_uuid);

  Future<String?> readRefreshToken() async {
    final token = await _delegate.readRefreshToken();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<DateTime?> readRefreshExpiresAt() => _delegate.readRefreshExpiresAt();

  Future<void> writeRefreshToken({
    required String refreshToken,
    required DateTime expiresAt,
  }) =>
      _delegate.writeRefreshToken(
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      );

  /// 注销 / 切租户 / refresh 失效时调用。**不清** device_id：
  /// 同一台设备保持稳定 device_id 是 refresh 绑定校验的前提，重新登录拿新 refresh 仍要用旧 device_id。
  Future<void> clearTokens() => _delegate.clearTokens();

  /// 极端情况（设备重置 / 用户主动清除全部 IM 状态）才调用，会强制下次启动重生 device_id。
  Future<void> clearAll() => _delegate.clearAll();

  static _IMCredentialsStorageDelegate _buildDelegate(
    FlutterSecureStorage? injected,
  ) {
    if (injected != null) return _SecureIMCredentialsStorage(injected);
    if (Platform.isMacOS) {
      return const _MacOsIMCredentialsStorage();
    }
    return const _SecureIMCredentialsStorage(
      FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accountName: 'cn.qkfintech.zhiban.im',
          accessibility: KeychainAccessibility.first_unlock,
        ),
        mOptions: MacOsOptions(
          accountName: 'cn.qkfintech.zhiban.im',
          accessibility: KeychainAccessibility.first_unlock,
          useDataProtectionKeyChain: kReleaseMode,
        ),
      ),
    );
  }
}

abstract class _IMCredentialsStorageDelegate {
  Future<String> getOrCreateDeviceId(Uuid uuid);

  Future<String?> readRefreshToken();

  Future<DateTime?> readRefreshExpiresAt();

  Future<void> writeRefreshToken({
    required String refreshToken,
    required DateTime expiresAt,
  });

  Future<void> clearTokens();

  Future<void> clearAll();
}

class _SecureIMCredentialsStorage implements _IMCredentialsStorageDelegate {
  const _SecureIMCredentialsStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String> getOrCreateDeviceId(Uuid uuid) async {
    final existing =
        await _storage.read(key: IMCredentialsStorage._deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final generated = uuid.v4();
    await _storage.write(
      key: IMCredentialsStorage._deviceIdKey,
      value: generated,
    );
    return generated;
  }

  @override
  Future<String?> readRefreshToken() =>
      _storage.read(key: IMCredentialsStorage._refreshTokenKey);

  @override
  Future<DateTime?> readRefreshExpiresAt() async {
    final raw =
        await _storage.read(key: IMCredentialsStorage._refreshExpiresAtKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  @override
  Future<void> writeRefreshToken({
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    await _storage.write(
      key: IMCredentialsStorage._refreshTokenKey,
      value: refreshToken,
    );
    await _storage.write(
      key: IMCredentialsStorage._refreshExpiresAtKey,
      value: expiresAt.toUtc().toIso8601String(),
    );
  }

  @override
  Future<void> clearTokens() async {
    await _storage.delete(key: IMCredentialsStorage._refreshTokenKey);
    await _storage.delete(key: IMCredentialsStorage._refreshExpiresAtKey);
  }

  @override
  Future<void> clearAll() async {
    await _storage.delete(key: IMCredentialsStorage._deviceIdKey);
    await _storage.delete(key: IMCredentialsStorage._refreshTokenKey);
    await _storage.delete(key: IMCredentialsStorage._refreshExpiresAtKey);
  }
}

class _MacOsIMCredentialsStorage implements _IMCredentialsStorageDelegate {
  const _MacOsIMCredentialsStorage();

  @override
  Future<String> getOrCreateDeviceId(Uuid uuid) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(IMCredentialsStorage._deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final generated = uuid.v4();
    await prefs.setString(IMCredentialsStorage._deviceIdKey, generated);
    return generated;
  }

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<DateTime?> readRefreshExpiresAt() async => null;

  @override
  Future<void> writeRefreshToken({
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    // macOS builds avoid Keychain ACL prompts by not persisting the IM refresh
    // token. Startup can re-issue via the existing app session.
  }

  @override
  Future<void> clearTokens() async {}

  @override
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(IMCredentialsStorage._deviceIdKey);
  }
}
