import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The proof a scanning device sends during pairing, letting the QR-shower
/// verify "this device actually scanned my QR" WITHOUT the pairing key ever
/// being transmitted over the wire.
///
/// The pairing key is a shared secret established out-of-band (the scanner
/// reads it from the QR code visually). The proof is an HMAC-SHA256 over a
/// fixed context plus BOTH device IDs, keyed by that shared secret. This means:
///
///   * A device that did not scan the QR cannot produce a valid proof.
///   * A captured proof cannot be replayed to pair a DIFFERENT device, because
///     it is bound to the scanner's and shower's identities.
///   * The secret itself never appears in the HTTP request or response.
///
/// Replay of the exact same proof only re-pairs the same two devices, which is
/// idempotent, so no nonce/timestamp is required for this threat model.
///
/// The base64 comparison performed by the shower is not constant-time; with a
/// 122-bit key that is not a practical timing channel here.
String computePairingProof({
  required String pairingKey,
  required String scannerDeviceId,
  required String showerDeviceId,
}) {
  final mac = Hmac(sha256, utf8.encode(pairingKey));
  final message = 'nexus-pair-proof-v1:$scannerDeviceId:$showerDeviceId';
  return base64Encode(mac.convert(utf8.encode(message)).bytes);
}
