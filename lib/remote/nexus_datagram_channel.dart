import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Minimal reliable-UDP channel with AES-GCM encrypted payloads, designed
/// specifically for Nexus's remote hole-punch path.
///
/// Protocol:
///   • Wire format: [magic 2B "NX"] [flags 1B] [seq 4B] [payloadLen 2B] [payload NB]
///   • Flags: SYN=1, SYN_ACK=2, ACK=3, DATA=4, FIN=5, FIN_ACK=6, RESET=7
///   • DATA payloads are AES-GCM encrypted with the pairing-key-derived
///     transfer key. Handshake/FIN/RESET are in the clear.
///   • Reliability: stop-and-wait per direction. After sending DATA(seq=N),
///     wait for ACK(ack=N) before sending the next. Retransmit on timeout.
///   • Ordering: receiver only accepts in-order sequence numbers.
///
/// Lifecycle: the handshake (connect/accept) polls socket.receive() directly
/// with no stream listener. Once the handshake completes, a single stream
/// listener takes over the socket for the lifetime of the connection. This
/// avoids the RawDatagramSocket single-listener restriction.
class NexusDatagramChannel {
  // ---- protocol constants ------------------------------------------------

  static const _magic = 0x4E58; // "NX"
  static const headerSize = 9; // 2 magic + 1 flags + 4 seq + 2 payloadLen

  static const flagSyn = 1;
  static const flagSynAck = 2;
  static const flagAck = 3;
  static const flagData = 4;
  static const flagFin = 5;
  static const flagFinAck = 6;
  static const flagReset = 7;

  static const retransmitTimeout = Duration(milliseconds: 500);
  static const maxRetries = 5;
  static const _nonceLength = 12;
  static const _macLength = 16;

  static final _aes = AesGcm.with256bits();

  // ---- instance state -----------------------------------------------------

  final RawDatagramSocket _socket;
  final InternetAddress remoteAddress;
  final int remotePort;
  final List<int> _keyBytes;

  int _sendSeq = 0;
  int _recvSeq = 0;
  bool _connected = false;
  bool _closed = false;

  final _incomingController = StreamController<List<int>>.broadcast();
  StreamSubscription<RawSocketEvent>? _socketSub;

  /// When send() is waiting for an ACK, this completer receives it from the
  /// stream listener's dispatcher. Only one send() can be in flight at a time
  /// (stop-and-wait).
  Completer<bool>? _ackWaiter;

  NexusDatagramChannel._({
    required RawDatagramSocket socket,
    required this.remoteAddress,
    required this.remotePort,
    required List<int> keyBytes,
    int initialSendSeq = 0,
    int initialRecvSeq = 0,
  })  : _socket = socket,
        _keyBytes = keyBytes,
        _sendSeq = initialSendSeq,
        _recvSeq = initialRecvSeq;

  Stream<List<int>> get incoming => _incomingController.stream;
  bool get isConnected => _connected;
  bool get isClosed => _closed;

  // ---- packet building / parsing ------------------------------------------

  static Uint8List buildPacket(int flags, int seq, [List<int>? payload]) {
    final payloadBytes = payload ?? const [];
    final packet = Uint8List(headerSize + payloadBytes.length);
    final bd = ByteData.sublistView(packet);
    bd.setUint16(0, _magic);
    bd.setUint8(2, flags);
    bd.setUint32(3, seq);
    bd.setUint16(7, payloadBytes.length);
    packet.setAll(headerSize, payloadBytes);
    return packet;
  }

  static ParsedPacket? parseHeader(Uint8List data) {
    if (data.length < headerSize) return null;
    final bd = ByteData.sublistView(data);
    if (bd.getUint16(0) != _magic) return null;
    return ParsedPacket(
      flag: bd.getUint8(2),
      seq: bd.getUint32(3),
      payloadLen: bd.getUint16(7),
    );
  }

  static bool isSyn(Uint8List data) {
    final p = parseHeader(data);
    return p != null && p.flag == flagSyn;
  }

  // ---- encryption ---------------------------------------------------------

  Future<Uint8List?> _decrypt(Uint8List data) async {
    if (data.length < _nonceLength + _macLength) return null;
    try {
      final nonce = data.sublist(0, _nonceLength);
      final cipherText =
          data.sublist(_nonceLength, data.length - _macLength);
      final mac = data.sublist(data.length - _macLength);
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(_keyBytes),
      );
      return Uint8List.fromList(clear);
    } catch (_) {
      return null;
    }
  }

  // ---- send helpers -------------------------------------------------------

  void _sendRaw(Uint8List packet) {
    if (_closed) return;
    _socket.send(packet, remoteAddress, remotePort);
  }

  void _sendPacket(int flags, int seq, [List<int>? payload]) {
    _sendRaw(buildPacket(flags, seq, payload));
  }

  // ---- stream listener + dispatcher (connected state) ---------------------

  /// Starts the single stream listener that dispatches all incoming packets.
  void _startListening() {
    _socketSub?.cancel();
    _socketSub = _socket.listen((event) {
      if (event != RawSocketEvent.read || _closed) return;
      final datagram = _socket.receive();
      if (datagram == null) return;
      if (datagram.address != remoteAddress ||
          datagram.port != remotePort) {
        return;
      }
      final parsed = parseHeader(datagram.data);
      if (parsed == null) return;
      _dispatch(parsed, datagram.data);
    });
  }

  void _dispatch(ParsedPacket parsed, Uint8List raw) {
    switch (parsed.flag) {
      case flagAck:
        // Hand this to the ACK waiter, if any.
        final waiter = _ackWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(true);
        }
        break;
      case flagData:
        _processDataPacket(parsed, raw);
        break;
      case flagFin:
        _sendPacket(flagFinAck, parsed.seq);
        _close();
        break;
      case flagFinAck:
        _close();
        break;
      case flagReset:
        _close();
        break;
      default:
        break;
    }
  }

  // ---- data transfer (stop-and-wait) --------------------------------------

  /// Sends [data] reliably to the peer.
  Future<void> send(List<int> data) async {
    if (!_connected || _closed) {
      throw StateError('channel not connected');
    }

    final seq = _sendSeq;
    final encrypted = await _aes.encrypt(
      Uint8List.fromList(data),
      secretKey: SecretKey(_keyBytes),
      nonce: _aes.newNonce(),
    );
    final payload = (BytesBuilder(copy: false)
      ..add(encrypted.nonce)
      ..add(encrypted.cipherText)
      ..add(encrypted.mac.bytes))
        .toBytes();

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      _sendPacket(flagData, seq, payload);

      // Register for ACK via the stream listener.
      final completer = Completer<bool>();
      _ackWaiter = completer;

      // Timeout guard.
      final timeout = Future.delayed(retransmitTimeout, () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      final acked = await completer.future;
      timeout.ignore(); // don't cancel, just stop caring about it

      if (acked) {
        _ackWaiter = null;
        _sendSeq++;
        return;
      }
      if (_closed) {
        _ackWaiter = null;
        throw StateError('channel closed during send');
      }
    }
    _ackWaiter = null;
    throw StateError(
        'peer did not ACK seq=$seq after ${maxRetries + 1} attempts');
  }

  Future<void> _processDataPacket(ParsedPacket parsed, Uint8List raw) async {
    final payloadEnd = headerSize + parsed.payloadLen;
    if (raw.length < payloadEnd) return;
    final payload = raw.sublist(headerSize, payloadEnd);

    // Send ACK immediately.
    _sendPacket(flagAck, parsed.seq);

    // Only accept in-order.
    if (parsed.seq != _recvSeq) return;

    final decrypted = await _decrypt(payload);
    if (decrypted == null) return;

    _recvSeq++;
    _incomingController.add(decrypted);
  }

  // ---- handshake (initiator) ----------------------------------------------

  static Future<NexusDatagramChannel?> connect({
    required RawDatagramSocket socket,
    required InternetAddress remoteAddress,
    required int remotePort,
    required List<int> keyBytes,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final channel = NexusDatagramChannel._(
      socket: socket,
      remoteAddress: remoteAddress,
      remotePort: remotePort,
      keyBytes: keyBytes,
    );
    return channel._initiateHandshake(timeout);
  }

  Future<NexusDatagramChannel?> _initiateHandshake(Duration timeout) async {
    final sw = Stopwatch()..start();
    var retries = 0;

    _sendPacket(flagSyn, 0);

    // Poll for SYN_ACK using receive() — no stream listener yet.
    while (sw.elapsed < timeout) {
      final datagram = _socket.receive();
      if (datagram != null &&
          datagram.address == remoteAddress &&
          datagram.port == remotePort) {
        final parsed = parseHeader(datagram.data);
        if (parsed != null && parsed.flag == flagSynAck && parsed.seq == 0) {
          _sendPacket(flagAck, 0);
          _connected = true;
          _startListening(); // takes over the socket from here
          return this;
        }
        if (parsed != null && parsed.flag == flagReset) {
          return null;
        }
      }

      if (sw.elapsed > retransmitTimeout * (retries + 1)) {
        retries++;
        if (retries > maxRetries) break;
        _sendPacket(flagSyn, 0);
      }

      await Future.delayed(const Duration(milliseconds: 10));
    }

    _sendPacket(flagReset, 0);
    return null;
  }

  // ---- handshake (responder) ----------------------------------------------

  static Future<NexusDatagramChannel?> accept({
    required RawDatagramSocket socket,
    required InternetAddress remoteAddress,
    required int remotePort,
    required List<int> keyBytes,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();

    while (sw.elapsed < timeout) {
      final datagram = socket.receive();
      if (datagram == null) {
        await Future.delayed(const Duration(milliseconds: 10));
        continue;
      }

      final parsed = parseHeader(datagram.data);
      if (parsed == null) continue;

      if (parsed.flag == flagSyn && parsed.seq == 0) {
        // Send SYN_ACK.
        socket.send(
          buildPacket(flagSynAck, 0),
          datagram.address,
          datagram.port,
        );

        // Poll for ACK.
        final ackSw = Stopwatch()..start();
        while (ackSw.elapsed < const Duration(seconds: 3)) {
          final ack = socket.receive();
          if (ack != null &&
              ack.address == datagram.address &&
              ack.port == datagram.port) {
            final ackParsed = parseHeader(ack.data);
            if (ackParsed != null &&
                ackParsed.flag == flagAck &&
                ackParsed.seq == 0) {              final channel = NexusDatagramChannel._(
                  socket: socket,
                  remoteAddress: datagram.address,
                  remotePort: datagram.port,
                  keyBytes: keyBytes,
                  initialSendSeq: 0,
                  initialRecvSeq: 0,
              );
              channel._connected = true;
              channel._startListening();
              return channel;
            }
          }
          await Future.delayed(const Duration(milliseconds: 10));
        }
        // ACK didn't arrive — keep looking for another SYN.
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
    return null;
  }

  // ---- lifecycle ----------------------------------------------------------

  Future<void> close() async {
    if (_closed) return;
    _sendPacket(flagFin, _sendSeq);
    await Future.delayed(const Duration(milliseconds: 200));
    _close();
  }

  void reset() {
    if (_closed) return;
    _sendPacket(flagReset, 0);
    _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _connected = false;
    _socketSub?.cancel();
    _socketSub = null;
    _ackWaiter?.complete(false);
    _ackWaiter = null;
    _incomingController.close();
  }
}

class ParsedPacket {
  final int flag;
  final int seq;
  final int payloadLen;
  const ParsedPacket({
    required this.flag,
    required this.seq,
    required this.payloadLen,
  });
}
