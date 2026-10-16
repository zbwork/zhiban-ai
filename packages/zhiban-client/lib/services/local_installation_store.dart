import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Non-secret installation identifier. Authorization comes from the login session.
/// Deliberately never touches the old OS Keychain installation key.
class LocalInstallationStore {
  static final _pending = <String, Future<String>>{};
  static final _uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  static Future<String> loadOrCreate(String apiUrl) {
    final uri = Uri.parse(apiUrl);
    final normalized = uri
        .replace(
          host: uri.host == 'localhost' ? '127.0.0.1' : uri.host,
          path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
        )
        .toString();
    final key =
        'local_agent.installation.v2.${sha256.convert(utf8.encode(normalized))}';
    return _pending.putIfAbsent(
        key,
        () => _load(key).whenComplete(() {
              _pending.remove(key);
            }));
  }

  static Future<String> _load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null) {
      if (!_uuid.hasMatch(existing)) {
        throw StateError('本机设备编号无效，请重新配置客户端');
      }
      return existing;
    }
    final id = const Uuid().v4();
    if (!await prefs.setString(key, id)) {
      throw StateError('本机设备编号保存失败');
    }
    return id;
  }
}
