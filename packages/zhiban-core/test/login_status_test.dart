import 'package:zhiban_core/models/login_status.dart';
import 'package:test/test.dart';

void main() {
  test('parses login status devices and logs', () {
    final status = LoginStatus.fromJson({
      'currentDevice': {
        'deviceId': 'mac-001',
        'deviceName': 'Apple MacBook Pro',
        'deviceModel': 'MacBook Pro',
        'deviceBrand': 'Apple',
        'appVersion': '1.0.0',
        'isActive': true,
        'isCurrent': true,
        'updatedAt': '2026-05-07T10:00:00+08:00',
      },
      'devices': [
        {
          'deviceId': 'mac-001',
          'deviceName': 'Apple MacBook Pro',
          'isActive': true,
          'isCurrent': true,
        }
      ],
      'loginLogs': [
        {
          'loginType': 'sms',
          'loginIp': '192.168.1.*',
          'deviceName': 'Apple MacBook Pro',
          'appVersion': '1.0.0',
          'createdAt': '2026-05-07T10:00:00+08:00',
        }
      ],
    });

    expect(status.currentDevice?.displayName, 'Apple MacBook Pro');
    expect(status.currentDevice?.isCurrent, isTrue);
    expect(status.devices, hasLength(1));
    expect(status.loginLogs.single.displayDevice, 'Apple MacBook Pro');
    expect(status.loginLogs.single.loginIp, '192.168.1.*');
  });

  test('handles empty login status payload', () {
    final status = LoginStatus.fromJson({});

    expect(status.currentDevice, isNull);
    expect(status.devices, isEmpty);
    expect(status.loginLogs, isEmpty);
  });
}
