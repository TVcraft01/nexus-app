import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/crypto/pairing_proof.dart';
import 'package:nexus_app/crypto/transfer_keys.dart';

void main() {
  group('key derivation domain separation', () {
    test('transfer key and auth token are distinct', () {
      const pairingKey = 'a-shared-secret';
      final transfer = deriveTransferKeyBase64(pairingKey);
      final auth = deriveAuthTokenBase64(pairingKey);
      expect(transfer, isNot(auth));
      expect(transfer.length, greaterThan(16));
      expect(auth.length, greaterThan(16));
    });

    test('derivation is deterministic', () {
      const pairingKey = 'a-shared-secret';
      expect(deriveTransferKeyBase64(pairingKey),
          deriveTransferKeyBase64(pairingKey));
      expect(
          deriveAuthTokenBase64(pairingKey), deriveAuthTokenBase64(pairingKey));
    });

    test('different secrets produce different keys', () {
      expect(
          deriveTransferKeyBase64('a'), isNot(deriveTransferKeyBase64('b')));
      expect(deriveAuthTokenBase64('a'), isNot(deriveAuthTokenBase64('b')));
    });
  });

  group('computePairingProof', () {
    const key = 'qr-secret';

    test('is deterministic', () {
      expect(
        computePairingProof(
            pairingKey: key, scannerDeviceId: 'B', showerDeviceId: 'A'),
        computePairingProof(
            pairingKey: key, scannerDeviceId: 'B', showerDeviceId: 'A'),
      );
    });

    test('changes with a different pairing key', () {
      expect(
        computePairingProof(
            pairingKey: 'key1', scannerDeviceId: 'B', showerDeviceId: 'A'),
        isNot(computePairingProof(
            pairingKey: 'key2', scannerDeviceId: 'B', showerDeviceId: 'A')),
      );
    });

    test('changes with a different scanner identity', () {
      expect(
        computePairingProof(
            pairingKey: key, scannerDeviceId: 'B', showerDeviceId: 'A'),
        isNot(computePairingProof(
            pairingKey: key, scannerDeviceId: 'C', showerDeviceId: 'A')),
      );
    });

    test('changes with a different shower identity', () {
      expect(
        computePairingProof(
            pairingKey: key, scannerDeviceId: 'B', showerDeviceId: 'A'),
        isNot(computePairingProof(
            pairingKey: key, scannerDeviceId: 'B', showerDeviceId: 'Z')),
      );
    });

    test('never contains the raw key', () {
      final proof = computePairingProof(
          pairingKey: 'supersecretvalue', scannerDeviceId: 'B', showerDeviceId: 'A');
      expect(proof, isNot(contains('supersecretvalue')));
    });
  });
}
