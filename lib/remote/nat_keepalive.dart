import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Our public UDP endpoint as discovered by STUN.
class NatEndpoint {
  final String ip;
  final int port;

  const NatEndpoint(this.ip, this.port);

  String get hostPort => '$ip:$port';

  @override
  String toString() => hostPort;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NatEndpoint && ip == other.ip && port == other.port;

  @override
  int get hashCode => ip.hashCode ^ port.hashCode;
}

/// Keeps a single UDP socket alive through the NAT by periodically sending
/// STUN binding requests (every 25 s, well under the 30–60 s typical NAT
/// mapping timeout). The same socket is later used for incoming UDP
/// hole-punch traffic, so we do NOT close it between STUN probes.
///
/// Exposed publicly only via [endpoint] (the current public address) and
/// [socket] (the RawDatagramSocket the caller binds for receiving). The
/// STUN logic is entirely internal.
class NatKeepAlive {
  static const _stunHost = 'stun.l.google.com';
  static const _stunPort = 19302;
  static const _keepAliveInterval = Duration(seconds: 25);
  static const _stunTimeout = Duration(seconds: 3);

  static const _magicCookie = 0x2112A442;
  static const _bindingRequest = 0x0001;
  static const _bindingSuccessResponse = 0x0101;
  static const _xorMappedAddress = 0x0020;
  static const _mappedAddress = 0x0001;

  final Random _random = Random.secure();

  RawDatagramSocket? _socket;
  InternetAddress? _stunServer;
  Timer? _timer;
  NatEndpoint? _currentEndpoint;
  bool _running = false;

  /// The public UDP endpoint discovered by STUN, or null if no binding
  /// has succeeded yet.
  NatEndpoint? get endpoint => _currentEndpoint;

  /// The local UDP socket kept alive by periodic STUN probes. Only
  /// non-null after [start] and before [stop]. Used by the caller to
  /// receive incoming UDP packets (hole-punch traffic).
  RawDatagramSocket? get socket => _socket;

  /// The port this socket is bound to locally (useful for logging).
  int? get localPort => _socket?.port;

  /// Called when the public endpoint changes (NAT rotated the mapping).
  /// Receives the new [NatEndpoint].
  void Function(NatEndpoint endpoint)? onEndpointChanged;

  /// Resolves the STUN server hostname to an IPv4 address.
  Future<InternetAddress?> _resolveIpv4(String name) async {
    try {
      final addrs = await InternetAddress.lookup(name);
      for (final a in addrs) {
        if (a.type == InternetAddressType.IPv4) return a;
      }
    } catch (_) {}
    return null;
  }

  /// Builds a STUN binding request with a fresh transaction id.
  Uint8List _buildBindingRequest(List<int> txId) {
    final bytes = ByteData(20);
    bytes.setUint16(0, _bindingRequest);
    bytes.setUint16(2, 0); // message length = 0
    bytes.setUint32(4, _magicCookie);
    for (var i = 0; i < 12; i++) {
      bytes.setUint8(8 + i, txId[i]);
    }
    return bytes.buffer.asUint8List();
  }

  /// Parses a STUN binding success response, returning the mapped address
  /// only if the transaction id matches [txId].
  NatEndpoint? _parseResponse(Uint8List data, List<int> txId) {
    if (data.length < 20) return null;
    final bd = ByteData.sublistView(data);

    if (bd.getUint16(0) != _bindingSuccessResponse) return null;

    // Verify transaction id.
    for (var i = 0; i < 12; i++) {
      if (bd.getUint8(8 + i) != txId[i]) return null;
    }

    final length = bd.getUint16(2);
    final end = min(20 + length, data.length);
    var offset = 20;

    while (offset + 4 <= end) {
      final attrType = bd.getUint16(offset);
      final attrLen = bd.getUint16(offset + 2);
      final valueStart = offset + 4;
      if (valueStart + attrLen > data.length) break;

      if (attrType == _xorMappedAddress && attrLen >= 8) {
        if (data[valueStart + 1] != 0x01) {
          // Not IPv4 — skip.
        } else {
          final xPort = bd.getUint16(valueStart + 2);
          final xAddr = bd.getUint32(valueStart + 4);
          return NatEndpoint(
            _ipFromInt(xAddr ^ _magicCookie),
            xPort ^ (_magicCookie >> 16),
          );
        }
      } else if (attrType == _mappedAddress && attrLen >= 8) {
        if (data[valueStart + 1] == 0x01) {
          final bd2 = ByteData.sublistView(data);
          return NatEndpoint(
            _ipFromInt(bd2.getUint32(valueStart + 4)),
            bd2.getUint16(valueStart + 2),
          );
        }
      }

      offset = valueStart + attrLen + ((4 - (attrLen % 4)) % 4);
    }
    return null;
  }

  static String _ipFromInt(int v) =>
      '${(v >> 24) & 0xff}.${(v >> 16) & 0xff}.${(v >> 8) & 0xff}.${v & 0xff}';

  /// Sends one STUN binding request and waits for the response. Returns the
  /// new public endpoint, or null on timeout / parse failure.
  Future<NatEndpoint?> _bindOnce() async {
    final socket = _socket;
    final server = _stunServer;
    if (socket == null || server == null) return null;

    final txId = List<int>.generate(12, (_) => _random.nextInt(256));
    final completer = Completer<NatEndpoint?>();

    late final StreamSubscription<RawSocketEvent> sub;
    sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final parsed = _parseResponse(datagram.data, txId);
      if (parsed != null && !completer.isCompleted) {
        completer.complete(parsed);
      }
    });

    try {
      socket.send(_buildBindingRequest(txId), server, _stunPort);
      return await completer.future.timeout(_stunTimeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  /// Performs one STUN binding and updates the tracked endpoint. If the
  /// endpoint changed, fires [onEndpointChanged].
  Future<void> _tick() async {
    final result = await _bindOnce();
    if (result == null) return; // STUN unreachable — try again next tick.

    if (_currentEndpoint != result) {
      _currentEndpoint = result;
      onEndpointChanged?.call(result);
    }
  }

  /// Binds the UDP socket, resolves the STUN server, runs an initial probe,
  /// and starts the periodic timer.
  Future<void> start() async {
    if (_running) return;
    _running = true;

    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _stunServer ??= await _resolveIpv4(_stunHost);

    // Initial probe — don't block startup if STUN is slow.
    _tick();

    _timer?.cancel();
    _timer = Timer.periodic(_keepAliveInterval, (_) => _tick());
  }

  /// Stops the keep-alive timer and closes the socket.
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    _currentEndpoint = null;
  }
}
