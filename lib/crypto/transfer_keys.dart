import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Domain-separated key derivation for file-transfer encryption.
///
/// The QR pairing key is a UUID v4 (122 bits of entropy), so it is already a
/// strong secret. We still pass it through HKDF-SHA256 (RFC 5869) so the raw
/// UUID is never used directly as an AES key, and so the derived key is bound
/// to exactly one purpose ("nexus-aes-256-gcm-v1").
///
/// This runs synchronously so [PairedDevice] can derive its stored transfer
/// key while decoding JSON, without an async round trip.
Uint8List deriveTransferKey(String pairingKey) {
  final ikm = utf8.encode(pairingKey);

  // HKDF-Extract: PRK = HMAC-SHA256(salt, IKM). The salt is empty because the
  // IKM is already high-entropy; no stretching is needed.
  final prk = Hmac(sha256, const <int>[]).convert(ikm).bytes;

  // HKDF-Expand: one 32-byte block — HMAC-SHA256(PRK, info || 0x01).
  final info = utf8.encode('nexus-aes-256-gcm-v1');
  final okm = Hmac(sha256, prk).convert(<int>[...info, 0x01]).bytes;

  return Uint8List.fromList(okm);
}

/// The transfer key as a base64 string, for storage next to a paired device.
String deriveTransferKeyBase64(String pairingKey) =>
    base64Encode(deriveTransferKey(pairingKey));
