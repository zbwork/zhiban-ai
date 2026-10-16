import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/desktop_network_connectivity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('cn.qkfintech.zhiban/network');
  const events = 'cn.qkfintech.zhiban/network/events';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final network = DesktopNetworkConnectivity();

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(const MethodChannel(events), null);
  });

  test('native carrier snapshots share the same mapping on both desktops',
      () async {
    for (final entry in {
      'wifi': ConnectivityResult.wifi,
      'ethernet': ConnectivityResult.ethernet,
      'mobile': ConnectivityResult.mobile,
      'none': ConnectivityResult.none,
    }.entries) {
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'check');
        return [entry.key];
      });
      expect(await network.checkConnectivity(), [entry.value]);
    }
  });

  test('missing, invalid and failed native observations never become offline',
      () async {
    for (final snapshot in [
      null,
      <String>[],
      ['vpn'],
      ['other']
    ]) {
      messenger.setMockMethodCallHandler(methods, (_) async => snapshot);
      await expectLater(network.checkConnectivity(), throwsFormatException);
    }
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(code: 'network_check_failed');
    });
    await expectLater(
        network.checkConnectivity(), throwsA(isA<PlatformException>()));
  });

  test('native changes preserve offline/recovery and release subscription',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel(events),
        (call) async {
      calls.add(call.method);
      return null;
    });
    final observations = <List<ConnectivityResult>>[];
    final errors = <Object>[];
    final sub = network.onConnectivityChanged
        .listen(observations.add, onError: errors.add);
    await Future<void>.delayed(Duration.zero);
    for (final value in [
      ['wifi'],
      ['none'],
      ['ethernet']
    ]) {
      await messenger.handlePlatformMessage(
          events, codec.encodeSuccessEnvelope(value), (_) {});
    }
    await messenger.handlePlatformMessage(events,
        codec.encodeErrorEnvelope(code: 'network_monitor_failed'), (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(observations, [
      [ConnectivityResult.wifi],
      [ConnectivityResult.none],
      [ConnectivityResult.ethernet],
    ]);
    expect(errors.single, isA<PlatformException>());
    await sub.cancel();
    expect(calls, ['listen', 'cancel']);
  });
}
