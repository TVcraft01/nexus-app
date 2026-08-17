/// Single-shot AES-GCM box for task payloads, using the same algorithm and
/// the same pairing-key-derived key as file transfer. Task data (file
/// contents being summarized, and the summaries that come back) never travels
/// in cleartext.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final AesGcm _aes = AesGcm.with256bits();

const int _nonceLength = 12;
const int _macLength = 16;

/// Wire format: nonce (12 bytes) || ciphertext || GCM tag (16 bytes).
Future<Uint8List> encryptTaskPayload(
  List<int> plaintext,
  List<int> keyBytes,
) async {
  final box = await _aes.encrypt(
    Uint8List.fromList(plaintext),
    secretKey: SecretKey(keyBytes),
    nonce: _aes.newNonce(),
  );
  final out = BytesBuilder(copy: false);
  out.add(box.nonce);
  out.add(box.cipherText);
  out.add(box.mac.bytes);
  return out.toBytes();
}

/// Reverses [encryptTaskPayload]. Throws if the tag does not verify or the
/// buffer is truncated, so a tampered/partial payload is never acted on.
Future<Uint8List> decryptTaskPayload(
  List<int> data,
  List<int> keyBytes,
) async {
  if (data.length < _nonceLength + _macLength) {
    throw const FormatException('task payload too short');
  }
  final nonce = data.sublist(0, _nonceLength);
  final cipherText = data.sublist(_nonceLength, data.length - _macLength);
  final mac = data.sublist(data.length - _macLength);
  final clear = await _aes.decrypt(
    SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
    secretKey: SecretKey(keyBytes),
  );
  return Uint8List.fromList(clear);
}
