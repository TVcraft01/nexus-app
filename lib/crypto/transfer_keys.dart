import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Domain-separated key derivation for Nexus's shared pairing secret.
///
/// The QR pairing key is a UUID v4 (122 bits of entropy), so it is already a
/// strong secret. We still pass it through HKDF-SHA256 (RFC 5869) so the raw
/// UUID is never used directly as an AES key or an auth token, and so each
/// derived value is bound to exactly one purpose via a distinct `info` string.
///
/// Two keys are derived from the single pairing secret:
///   * [deriveTransferKey]  — "nexus-aes-256-gcm-v1", the AES-256 key that
///     encrypts file transfers, sync payloads, and task payloads.
///   * [deriveAuthToken]    — "nexus-auth-token-v1", a bearer token sent in
///     the `x-nexus-key` header to authenticate requests.
///
/// They are deliberately DIFFERENT so that a leaked auth token (which travels
/// on every request) does not let an attacker decrypt transferred data.
///
/// This runs synchronously so [PairedDevice] can derive its stored values
/// while decoding JSON, without an async round trip.
Uint8List _hkdf(String pairingKey, String info) {
  final ikm = utf8.encode(pairingKey);

  // HKDF-Extract: PRK = HMAC-SHA256(salt, IKM). The salt is empty because the
  // IKM is already high-entropy; no stretching is needed.
  final prk = Hmac(sha256, const <int>[]).convert(ikm).bytes;

  // HKDF-Expand: one 32-byte block — HMAC-SHA256(PRK, info || 0x01).
  final okm = Hmac(sha256, prk).convert(<int>[...utf8.encode(info), 0x01]).bytes;

  return Uint8List.fromList(okm);
}

/// The AES-256 file/transfer key as raw bytes.
Uint8List deriveTransferKey(String pairingKey) =>
    _hkdf(pairingKey, 'nexus-aes-256-gcm-v1');

/// The bearer auth token as raw bytes.
Uint8List deriveAuthToken(String pairingKey) =>
    _hkdf(pairingKey, 'nexus-auth-token-v1');

/// The transfer key as a base64 string, for storage next to a paired device.
String deriveTransferKeyBase64(String pairingKey) =>
    base64Encode(deriveTransferKey(pairingKey));

/// The auth token as a base64 string, for storage next to a paired device and
/// transmission in the `x-nexus-key` header.
String deriveAuthTokenBase64(String pairingKey) =>
    base64Encode(deriveAuthToken(pairingKey));
