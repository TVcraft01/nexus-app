import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/paired_device.dart';
import '../pairing/pairing_service.dart';
import '../remote/nat_keepalive.dart';
import '../remote/nexus_datagram_channel.dart';
import '../remote/remote_access_service.dart';
import '../transfer/transfer_service.dart';

/// Listens for incoming NexusDatagramChannel connections on the UDP socket
/// kept alive by [NatKeepAlive]. When a connection is established, it
/// accepts the handshake and processes the incoming file-transfer payload.
///
/// Wire format (same as the HTTP /receive path, just over UDP):
///   [4-byte request length] [request JSON] [encrypted body]
///
/// Request JSON: { "filename": "...", "sender": "...", "bodyLen": N }
/// The body is the same NEXUS1 + chunked AES-GCM format as the HTTP path.
///
/// This only runs on the PC (the device being reached), not on the phone.
///
/// This class does NOT listen on the socket directly. Instead, it receives
/// datagrams via [handleDatagram], called by [NatKeepAlive.onIncomingDatagram]
/// — NatKeepAlive is the sole listener on the socket.
class UdpReceiveServer {
  final PairingService _pairing = PairingService();
  final TransferService _transfer = TransferService();
  final Map<String, NexusDatagramChannel> _channels = {};
  bool _running = false;

  /// Callback invoked when a file is successfully received over UDP.
  void Function(ReceivedFile file)? onFileReceived;

  /// Starts the server by registering with [keepAlive]'s packet callback.
  void start(NatKeepAlive keepAlive) {
    if (_running) return;
    _running = true;
    keepAlive.onIncomingDatagram = handleDatagram;
  }

  /// Called by NatKeepAlive for every non-STUN datagram. Checks for SYN
  /// packets and initiates the handshake.
  void handleDatagram(Datagram dg) {
    if (!NexusDatagramChannel.isSyn(dg.data)) return;

    // ignore: avoid_print
    print('[UDP-RECV] SYN from ${dg.address.address}:${dg.port}');

    final socket = RemoteAccessService.instance.udpSocket;
    if (socket == null) return;

    final key = '${dg.address.address}:${dg.port}';
    if (_channels.containsKey(key)) return;

    _acceptConnection(socket, dg.address, dg.port, key);
  }

  Future<void> _acceptConnection(
    RawDatagramSocket socket,
    InternetAddress remoteAddress,
    int remotePort,
    String channelKey,
  ) async {
    final channel = await NexusDatagramChannel.accept(
      socket: socket,
      remoteAddress: remoteAddress,
      remotePort: remotePort,
      keyBytes: const [], // placeholder — key comes from the payload
      timeout: const Duration(seconds: 5),
    );

    if (channel == null) return;
    _channels[channelKey] = channel;

    channel.incoming.listen(
      (payload) => _processPayload(channel, payload),
      onDone: () => _channels.remove(channelKey),
    );
  }

  Future<void> _processPayload(
    NexusDatagramChannel channel,
    List<int> payload,
  ) async {
    // Parse the request envelope: [4-byte request length][request JSON][body]
    if (payload.length < 4) {
      await channel.send(
          utf8.encode('{"status":"error","message":"payload too short"}'));
      return;
    }

    final raw = Uint8List.fromList(payload);
    final reqLen = ByteData.sublistView(raw).getUint32(0, Endian.big);
    if (raw.length < 4 + reqLen) {
      await channel.send(
          utf8.encode('{"status":"error","message":"truncated request"}'));
      return;
    }

    final requestJson = utf8.decode(raw.sublist(4, 4 + reqLen));
    final request = jsonDecode(requestJson) as Map<String, dynamic>;
    final bodyBytes = raw.sublist(4 + reqLen);

    final encodedFilename = request['filename'] as String? ?? 'received_file';

    // Identify the sender by trying each paired device's transfer key.
    final devices = await _pairing.getPairedDevices();
    PairedDevice? sender;

    for (final device in devices) {
      try {
        final keyBytes = base64Decode(device.transferKey);
        await _verifyKey(bodyBytes, keyBytes);
        sender = device;
        break;
      } catch (_) {
        continue;
      }
    }

    if (sender == null) {
      await channel.send(
          utf8.encode('{"status":"error","message":"unpaired device"}'));
      return;
    }

    try {
      final received = await _transfer.receiveFromUdp(
        bodyBytes,
        sender,
        fileName: Uri.decodeComponent(encodedFilename),
      );
      onFileReceived?.call(received);
      final myPublic = RemoteAccessService.instance.publicAddress;
      await channel.send(utf8.encode(jsonEncode({
        'status': 'ok',
        if (myPublic != null) 'publicAddress': myPublic,
      })));
    } catch (e) {
      await channel.send(
          utf8.encode('{"status":"error","message":"$e"}'));
    }
  }

  /// Minimal key verification: try to decrypt the first chunk with the
  /// given key. Throws on failure.
  Future<void> _verifyKey(List<int> data, List<int> keyBytes) async {
    if (data.length < 10) throw StateError('truncated');
    final raw = Uint8List.fromList(data);
    final magic = String.fromCharCodes(raw.sublist(0, 6));
    if (magic != 'NEXUS1') throw StateError('bad magic');
    // Skip 6-byte magic + 4-byte total length
    var offset = 10;
    if (data.length < offset + 12 + 4 + 16) throw StateError('truncated');
    final nonce = data.sublist(offset, offset + 12);
    offset += 12;
    final cipherLen = ByteData.sublistView(
            Uint8List.fromList(data.sublist(offset, offset + 4)))
        .getUint32(0, Endian.big);
    offset += 4;
    if (data.length < offset + cipherLen + 16) throw StateError('truncated');
    final cipherText = data.sublist(offset, offset + cipherLen);
    offset += cipherLen;
    final mac = data.sublist(offset, offset + 16);

    final aes = AesGcm.with256bits();
    await aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(keyBytes),
    );
    // If decrypt succeeds, the key is correct.
  }
}
