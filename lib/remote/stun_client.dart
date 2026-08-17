import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The public address a STUN server reports back for us: our NAT's external
/// IP and the external port it mapped for the socket we used.
class StunResult {
  final String publicIp;
  final int publicPort;

  const StunResult(this.publicIp, this.publicPort);
}

/// Minimal STUN (RFC 5389) binding-request client, implemented directly over
/// dart:io datagram sockets so it works on Android and Linux with no native
/// plugin. Used ONLY to learn this device's public IP/port — it never carries
/// user data (no file bytes, commands, or messages ever touch it).
///
/// Default server is Google's public STUN (`stun.l.google.com:19302`).
class StunClient {
  static const _magicCookie = 0x2112A442;
  static const _bindingRequest = 0x0001;
  static const _bindingSuccessResponse = 0x0101;

  // Attribute types.
  static const _xorMappedAddress = 0x0020;
  static const _mappedAddress = 0x0001;

  final String host;
  final int port;
  final Duration timeout;

  final Random _random = Random.secure();

  StunClient({
    this.host = 'stun.l.google.com',
    this.port = 19302,
    this.timeout = const Duration(seconds: 3),
  });

  /// Sends a binding request and returns our public address, or null if the
  /// server was unreachable or the response couldn't be parsed.
  Future<StunResult?> discover() async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      return null;
    }

    try {
      // Resolve the hostname to an IPv4 address first (InternetAddress(host)
      // only accepts IP literals).
      final server = await _resolveIpv4(host);
      if (server == null) return null;

      final txId = List<int>.generate(12, (_) => _random.nextInt(256));
      final completer = Completer<StunResult?>();

      late final StreamSubscription<RawSocketEvent> sub;
      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final parsed = _parseBindingResponse(datagram.data, txId);
        if (parsed != null && !completer.isCompleted) {
          completer.complete(parsed);
        }
      });

      try {
        socket.send(_buildBindingRequest(txId), server, port);
        return await completer.future
            .timeout(timeout, onTimeout: () => null);
      } finally {
        await sub.cancel();
      }
    } finally {
      socket.close();
    }
  }

  Future<InternetAddress?> _resolveIpv4(String name) async {
    try {
      final addrs = await InternetAddress.lookup(name);
      for (final a in addrs) {
        if (a.type == InternetAddressType.IPv4) return a;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Uint8List _buildBindingRequest(List<int> txId) {
    final bytes = ByteData(20);
    bytes.setUint16(0, _bindingRequest);
    bytes.setUint16(2, 0); // no attributes -> message length 0
    bytes.setUint32(4, _magicCookie);
    for (var i = 0; i < 12; i++) {
      bytes.setUint8(8 + i, txId[i]);
    }
    return bytes.buffer.asUint8List();
  }

  StunResult? _parseBindingResponse(Uint8List data, List<int> txId) {
    if (data.length < 20) return null;
    final bd = ByteData.sublistView(data);

    final type = bd.getUint16(0);
    if (type != _bindingSuccessResponse) return null;

    // Verify the transaction id matches ours so we ignore stray datagrams.
    for (var i = 0; i < 12; i++) {
      if (bd.getUint8(8 + i) != txId[i]) return null;
    }

    final length = bd.getUint16(2);
    final end = (20 + length).clamp(0, data.length);
    var offset = 20;

    while (offset + 4 <= end) {
      final attrType = bd.getUint16(offset);
      final attrLen = bd.getUint16(offset + 2);
      final valueStart = offset + 4;
      if (valueStart + attrLen > data.length) break;

      if (attrType == _xorMappedAddress) {
        return _parseXorMapped(data, valueStart, attrLen);
      } else if (attrType == _mappedAddress) {
        return _parseMapped(data, valueStart, attrLen);
      }

      // Attributes are padded to a 4-byte boundary.
      offset = valueStart + attrLen + ((4 - (attrLen % 4)) % 4);
    }
    return null;
  }

  StunResult? _parseXorMapped(Uint8List data, int start, int len) {
    if (len < 8 || data[start + 1] != 0x01) return null; // IPv4 only
    final bd = ByteData.sublistView(data);
    final xPort = bd.getUint16(start + 2);
    final xAddr = bd.getUint32(start + 4);
    return StunResult(
      _ipFromInt(xAddr ^ _magicCookie),
      xPort ^ (_magicCookie >> 16),
    );
  }

  StunResult? _parseMapped(Uint8List data, int start, int len) {
    if (len < 8 || data[start + 1] != 0x01) return null; // IPv4 only
    final bd = ByteData.sublistView(data);
    return StunResult(
      _ipFromInt(bd.getUint32(start + 4)),
      bd.getUint16(start + 2),
    );
  }

  static String _ipFromInt(int v) =>
      '${(v >> 24) & 0xff}.${(v >> 16) & 0xff}.${(v >> 8) & 0xff}.${v & 0xff}';
}
