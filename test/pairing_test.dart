import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/models/paired_device.dart';
import 'package:nexus_app/pairing/pairing_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('public identity serialization', () {
    test('toPublicJson excludes all secret material', () {
      final device = PairedDevice(
        deviceId: 'A',
        deviceName: 'PC',
        ipAddress: '192.168.1.2',
        port: 51820,
        pairingKey: 'qr-secret',
        publicAddress: '1.2.3.4:9999',
        platform: 'linux',
      );
      final json = device.toPublicJson();
      expect(json.keys, isNot(contains('pairingKey')));
      expect(json.keys, isNot(contains('transferKey')));
      expect(json.keys, isNot(contains('authToken')));
      expect(json['deviceId'], 'A');
      expect(json['publicAddress'], '1.2.3.4:9999');
      expect(json['platform'], 'linux');
    });

    test('fromPublicJson derives transfer key and auth token from the QR key',
        () {
      final json = <String, dynamic>{
        'deviceId': 'A',
        'deviceName': 'PC',
        'ipAddress': '192.168.1.2',
        'port': 51820,
        'platform': 'linux',
      };
      final device = PairedDevice.fromPublicJson(json, pairingKey: 'qr-secret');
      expect(device.pairingKey, 'qr-secret');
      expect(device.transferKey, isNotEmpty);
      expect(device.authToken, isNotEmpty);

      // Derived deterministically, never received from the peer.
      final again = PairedDevice.fromPublicJson(json, pairingKey: 'qr-secret');
      expect(device.transferKey, again.transferKey);
      expect(device.authToken, again.authToken);
    });
  });

  group('pairing handshake', () {
    PairedDevice showerDevice() => PairedDevice(
          deviceId: 'shower-1',
          deviceName: 'Shower PC',
          ipAddress: '127.0.0.1',
          port: PairingService.pairingPort,
          pairingKey: 'qr-shared-secret',
          platform: 'linux',
        );

    PairedDevice scannerDevice() => PairedDevice(
          deviceId: 'scanner-1',
          deviceName: 'Scanner Phone',
          ipAddress: '127.0.0.1',
          port: 0,
          pairingKey: 'scanner-local-key',
          platform: 'android',
        );

    test('both sides converge on the QR secret without it crossing the wire',
        () async {
      final shower = PairingService();
      PairedDevice? pairedWith;
      await shower.startListening(
        thisDevice: showerDevice(),
        onPaired: (d) => pairedWith = d,
      );
      addTearDown(shower.stopListening);

      final scanner = PairingService();
      final confirmed = await scanner.pairWithScannedDevice(
        scannedDevice: showerDevice(),
        thisDevice: scannerDevice(),
      );

      expect(confirmed.pairingKey, 'qr-shared-secret');
      expect(pairedWith?.deviceId, 'scanner-1');
      expect(pairedWith?.pairingKey, 'qr-shared-secret');
      // Both sides derive the same transfer/auth material from the shared key.
      expect(confirmed.transferKey, pairedWith?.transferKey);
      expect(confirmed.authToken, pairedWith?.authToken);
    });

    test('a wrong pairing key is rejected', () async {
      final shower = PairingService();
      await shower.startListening(
        thisDevice: showerDevice(),
        onPaired: (_) {},
      );
      addTearDown(shower.stopListening);

      final scanner = PairingService();
      // A device that did not scan the real QR (wrong secret) fails the proof.
      final wrongQr = showerDevice().copyWith(pairingKey: 'not-the-real-key');
      await expectLater(
        scanner.pairWithScannedDevice(
          scannedDevice: wrongQr,
          thisDevice: scannerDevice(),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
