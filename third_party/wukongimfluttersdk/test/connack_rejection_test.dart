import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wukongimfluttersdk/wkim.dart';
import 'package:wukongimfluttersdk/proto/proto.dart';
import 'package:wukongimfluttersdk/proto/packet.dart';

void main() {
  test(
    'v1.2.6 invalid token CONNACK preserves rejection without v4 node ID',
    () {
      final previous = WKIM.shared.options.protoVersion;
      addTearDown(() => WKIM.shared.options.protoVersion = previous);
      WKIM.shared.options.protoVersion = 4;
      // Captured from a real v1.2.6 server rejecting a revoked member token.
      final packet =
          Proto().decode(
                Uint8List.fromList([
                  0x20,
                  13,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  2,
                  0,
                  0,
                  0,
                  0,
                ]),
              )
              as ConnackPacket;
      expect(packet.reasonCode, 2);
      expect(packet.nodeId, 0);
    },
  );
  test('successful v4 CONNACK still decodes its node ID', () {
    final previous = WKIM.shared.options.protoVersion;
    addTearDown(() => WKIM.shared.options.protoVersion = previous);
    WKIM.shared.options.protoVersion = 4;
    final packet =
        Proto().decode(
              Uint8List.fromList([
                0x21,
                22,
                4,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                7,
              ]),
            )
            as ConnackPacket;
    expect(packet.reasonCode, 1);
    expect(packet.serviceProtoVersion, 4);
    expect(packet.nodeId, 7);
  });
}
