import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

/// Physical desktop network observations. VPN presence is not a carrier.
/// Errors deliberately propagate: an unavailable monitor is not offline.
class DesktopNetworkConnectivity {
  static const _methods = MethodChannel('cn.qkfintech.zhiban/network');
  static const _events = EventChannel('cn.qkfintech.zhiban/network/events');

  Future<List<ConnectivityResult>> checkConnectivity() async =>
      _decode(await _methods.invokeMethod<Object?>('check'));

  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _events.receiveBroadcastStream().map(_decode);

  static List<ConnectivityResult> _decode(Object? value) {
    if (value is! List || value.isEmpty) {
      throw const FormatException('Missing desktop network observation');
    }
    return value
        .map((type) => switch (type) {
              'wifi' => ConnectivityResult.wifi,
              'ethernet' => ConnectivityResult.ethernet,
              'mobile' => ConnectivityResult.mobile,
              'none' => ConnectivityResult.none,
              _ => throw FormatException('Invalid desktop network type: $type'),
            })
        .toList();
  }
}
