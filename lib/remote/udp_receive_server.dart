import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/paired_device.dart';
import '../pairing/pairing_service.dart';
import '../remote/nat_keepalive.dart';
import '../remote/nexus_datagram_channel.dart';
import '../transfer/transfer_service.dart';

/// Listens for incoming NexusDatagramChannel connections on the UDP socket
/// kept alive by [NatKeepAlive]. When a connection is established, it
/// accepts the handshake and processes the incoming file-transfer payload.
///
/// The phone sends encrypted transfer data (same wire format as the HTTP
/// POST body for /receive) over the reliable channel. This server
/// identifies the sender by trying each paired device's transfer key and
/// delegates to [TransferService.receiveFromUdp] for decryption and
/// storage.
///
/// This only runs on the PC (the device being reached), not on the phone.
class UdpReceiveServer {
  final PairingService _pairing = PairingService();
  final TransferService _transfer = TransferService();
  final Map<String, NexusDatagramChannel> _channels = {};
  StreamSubscription<RawSocketEvent>? _socketSub;
  bool _running = false;

  /// Callback invoked when a file is successfully received over UDP.
  void Function(ReceivedFile file)? onFileReceived;

  /// Starts listening for incoming SYN packets on the keep-alive socket
  /// and completing handshakes.
  void start(NatKeepAlive keepAlive) {
    if (_running) return;
    _running = true;

    final socket = keepAlive.socket;
    if (socket == null) return;

    _socketSub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;

      if (!NexusDatagramChannel.isSyn(datagram.data)) return;

      final key = '${datagram.address.address}:${datagram.port}';
      if (_channels.containsKey(key)) return;

      _acceptConnection(socket, datagram.address, datagram.port, key);
    });
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
    if (payload.length < 10) {
      await channel.send(
          utf8.encode('{"status":"error","message":"payload too short"}'));
      return;
    }

    final raw = Uint8List.fromList(payload);
    final magicBytes = String.fromCharCodes(raw.sublist(0, 6));
    if (magicBytes != 'NEXUS1') {
      await channel.send(
          utf8.encode('{"status":"error","message":"bad magic"}'));
      return;
    }

    final devices = await _pairing.getPairedDevices();
    PairedDevice? sender;

    for (final device in devices) {
      try {
        final keyBytes = base64Decode(device.transferKey);
        await _verifyKey(raw.sublist(6), keyBytes);
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
      final received = await _transfer.receiveFromUdp(payload, sender);
      onFileReceived?.call(received);
      await channel.send(utf8.encode('{"status":"ok"}'));
    } catch (e) {
      await channel.send(
          utf8.encode('{"status":"error","message":"$e"}'));
    }
  }

  /// Minimal key verification: try to decrypt the first chunk with the
  /// given key. Throws on failure.
  Future<void> _verifyKey(List<int> data, List<int> keyBytes) async {
    if (data.length < 4) throw StateError('truncated');
    var offset = 4; // skip 4-byte total length
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
  }

  void stop() {
    _running = false;
    _socketSub?.cancel();
    _socketSub = null;
    for (final ch in _channels.values) {
      ch.close();
    }
    _channels.clear();
  }
}
