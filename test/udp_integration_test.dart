import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/crypto/transfer_keys.dart';
import 'package:nexus_app/remote/nexus_datagram_channel.dart';
import 'package:nexus_app/remote/remote_access_service.dart';

/// Test key matching what TransferService / UdpReceiveServer use.
final _testKey = deriveTransferKey('test-pairing-key-uuid-v4');

/// Build a minimal valid NEXUS1 encrypted transfer body with a single chunk.
Future<Uint8List> _buildEncryptedBody(
    Uint8List plaintext, List<int> keyBytes) async {
  final aes = AesGcm.with256bits();
  final box = await aes.encrypt(
    plaintext,
    secretKey: SecretKey(keyBytes),
    nonce: aes.newNonce(),
  );
  final body = BytesBuilder(copy: false)
    ..add(ascii.encode('NEXUS1')) // 6-byte magic
    ..add(_uint32(plaintext.length)) // 4-byte total plaintext length
    ..add(box.nonce) // 12-byte nonce
    ..add(_uint32(box.cipherText.length)) // 4-byte ciphertext length
    ..add(box.cipherText) // ciphertext
    ..add(box.mac.bytes); // 16-byte GCM tag
  return body.toBytes();
}

Uint8List _uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
  return bytes;
}

/// Build the wire envelope: [4B reqLen][JSON request][encrypted body].
Uint8List _buildEnvelope(
  Uint8List encryptedBody, {
  String filename = 'test.txt',
  String sender = 'Phone',
}) {
  final request = utf8.encode(jsonEncode({
    'filename': filename,
    'sender': sender,
    'bodyLen': encryptedBody.length,
  }));
  return (BytesBuilder(copy: false)
        ..add(_uint32(request.length))
        ..add(request)
        ..add(encryptedBody))
      .toBytes();
}

/// Verify the key of an encrypted body. Returns true if the key matches.
Future<bool> _verifyKey(Uint8List bodyBytes, List<int> keyBytes) async {
  final magic = String.fromCharCodes(bodyBytes.sublist(0, 6));
  if (magic != 'NEXUS1') return false;
  const chunkOffset = 10; // skip magic(6) + totalLen(4)
  if (bodyBytes.length < chunkOffset + 12 + 4 + 16) return false;
  final nonce = bodyBytes.sublist(chunkOffset, chunkOffset + 12);
  final cipherLen = ByteData.sublistView(
          Uint8List.fromList(bodyBytes.sublist(chunkOffset + 12, chunkOffset + 16)))
      .getUint32(0, Endian.big);
  if (bodyBytes.length < chunkOffset + 16 + cipherLen + 16) return false;
  final cipherText =
      bodyBytes.sublist(chunkOffset + 16, chunkOffset + 16 + cipherLen);
  final mac = bodyBytes.sublist(
      chunkOffset + 16 + cipherLen, chunkOffset + 16 + cipherLen + 16);

  try {
    final aes = AesGcm.with256bits();
    await aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(keyBytes),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// Helper: set up a connected client+server pair on loopback.
Future<(NexusDatagramChannel client, NexusDatagramChannel server,
    RawDatagramSocket clientSock, RawDatagramSocket serverSock)>
    _connectedPair() async {
  final serverSocket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4, 0);
  final clientSocket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4, 0);

  final acceptFuture = NexusDatagramChannel.accept(
    socket: serverSocket,
    remoteAddress: InternetAddress.loopbackIPv4,
    remotePort: clientSocket.port,
    keyBytes: _testKey,
  );
  final connectFuture = NexusDatagramChannel.connect(
    socket: clientSocket,
    remoteAddress: InternetAddress.loopbackIPv4,
    remotePort: serverSocket.port,
    keyBytes: _testKey,
  );

  final results = await Future.wait([connectFuture, acceptFuture]);
  return (results[0]!, results[1]!, clientSocket, serverSocket);
}

void main() {
  group('UDP file transfer round-trip', () {
    test('small envelope arrives intact over UDP channel', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final fileContent =
          Uint8List.fromList(utf8.encode('Hello from the phone!'));
      final encryptedBody = await _buildEncryptedBody(fileContent, _testKey);
      final envelope = _buildEnvelope(encryptedBody,
          filename: 'test.txt', sender: 'Phone');

      // Server listens; client sends.
      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));
      await client.send(envelope);
      final received = await receivedFuture;

      expect(received, envelope);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('server can parse request envelope from received payload', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final fileContent = Uint8List.fromList(utf8.encode('data'));
      final encryptedBody = await _buildEncryptedBody(fileContent, _testKey);
      final envelope = _buildEnvelope(encryptedBody,
          filename: 'photo.jpg', sender: 'Test Phone');

      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));
      await client.send(envelope);
      final received = await receivedFuture;

      // Parse the envelope.
      final raw = Uint8List.fromList(received);
      final reqLen = ByteData.sublistView(raw).getUint32(0, Endian.big);
      final requestJson = utf8.decode(raw.sublist(4, 4 + reqLen));
      final parsed = jsonDecode(requestJson) as Map<String, dynamic>;

      expect(parsed['filename'], 'photo.jpg');
      expect(parsed['sender'], 'Test Phone');
      expect(parsed['bodyLen'], encryptedBody.length);

      final bodyBytes = raw.sublist(4 + reqLen);
      expect(bodyBytes.length, encryptedBody.length);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('server sends ok response that client receives', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final fileContent = Uint8List.fromList(utf8.encode('test'));
      final encryptedBody = await _buildEncryptedBody(fileContent, _testKey);
      final envelope = _buildEnvelope(encryptedBody);

      // Start client listening for the response BEFORE sending.
      final responseFuture =
          client.incoming.first.timeout(const Duration(seconds: 3));

      // Server echoes back a JSON response when it receives data.
      final sub = server.incoming.listen((_) async {
        await server.send(utf8.encode('{"status":"ok"}'));
      });

      await client.send(envelope);
      final response = await responseFuture;

      final parsed = jsonDecode(utf8.decode(response)) as Map<String, dynamic>;
      expect(parsed['status'], 'ok');

      await sub.cancel();
      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('wrong key fails verification on received body', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final wrongKey = deriveTransferKey('wrong-pairing-key');
      final fileContent = Uint8List.fromList(utf8.encode('secret'));
      final encryptedBody = await _buildEncryptedBody(fileContent, wrongKey);
      final envelope = _buildEnvelope(encryptedBody);

      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));
      await client.send(envelope);
      final received = await receivedFuture;

      final raw = Uint8List.fromList(received);
      final reqLen = ByteData.sublistView(raw).getUint32(0, Endian.big);
      final bodyBytes = raw.sublist(4 + reqLen);

      // Key verification with _testKey should fail (encrypted with wrongKey).
      expect(await _verifyKey(bodyBytes, _testKey), isFalse);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('correct key passes verification on received body', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final fileContent = Uint8List.fromList(utf8.encode('correct'));
      final encryptedBody = await _buildEncryptedBody(fileContent, _testKey);
      final envelope = _buildEnvelope(encryptedBody);

      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));
      await client.send(envelope);
      final received = await receivedFuture;

      final raw = Uint8List.fromList(received);
      final reqLen = ByteData.sublistView(raw).getUint32(0, Endian.big);
      final bodyBytes = raw.sublist(4 + reqLen);

      expect(await _verifyKey(bodyBytes, _testKey), isTrue);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('10KB file transfers correctly', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final rng = Random.secure();
      final fileContent = Uint8List(10240);
      for (var i = 0; i < fileContent.length; i++) {
        fileContent[i] = rng.nextInt(256);
      }

      final encryptedBody = await _buildEncryptedBody(fileContent, _testKey);
      final envelope = _buildEnvelope(encryptedBody, filename: 'big.bin');

      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 5));
      await client.send(envelope);
      final received = await receivedFuture;

      expect(received, envelope);

      // Verify key.
      final raw = Uint8List.fromList(received);
      final reqLen = ByteData.sublistView(raw).getUint32(0, Endian.big);
      final bodyBytes = raw.sublist(4 + reqLen);
      expect(await _verifyKey(bodyBytes, _testKey), isTrue);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });
  });

  group('sendFile decision logic', () {
    test('DeviceLinkStatus.remoteUdp is distinct from other statuses', () {
      final values = DeviceLinkStatus.values;
      expect(values.length, 5);
      expect(values.toSet().length, 5);
      expect(DeviceLinkStatus.remoteUdp, isNot(DeviceLinkStatus.remote));
      expect(DeviceLinkStatus.remoteUdp, isNot(DeviceLinkStatus.unreachable));
      expect(DeviceLinkStatus.remoteUdp, isNot(DeviceLinkStatus.local));
    });
  });
}
