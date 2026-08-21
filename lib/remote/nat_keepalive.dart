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
/// NatKeepAlive is the **sole** listener on the socket. Non-STUN packets
/// are forwarded to [onIncomingDatagram] so the UdpReceiveServer can handle
/// hole-punch traffic without competing for the socket's stream.
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

  /// Pending STUN response waiters keyed by hex-encoded transaction id
  /// (`List<int>` doesn't have value equality in Dart maps).
  final Map<String, Completer<NatEndpoint?>> _pendingStun = {};

  /// The public UDP endpoint discovered by STUN, or null if no binding
  /// has succeeded yet.
  NatEndpoint? get endpoint => _currentEndpoint;

  /// The local UDP socket kept alive by periodic STUN probes. Only
  /// non-null after [start] and before [stop].
  RawDatagramSocket? get socket => _socket;

  /// The port this socket is bound to locally (useful for logging).
  int? get localPort => _socket?.port;

  /// Called when the public endpoint changes (NAT rotated the mapping).
  void Function(NatEndpoint endpoint)? onEndpointChanged;

  /// Called for every incoming datagram that is NOT a STUN response.
  /// Used by UdpReceiveServer to receive hole-punch traffic.
  void Function(Datagram dg)? onIncomingDatagram;

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

  /// Encodes a transaction id list as a hex string for use as a map key.
  static String _txIdToKey(List<int> txId) =>
      txId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Checks whether [data] is a STUN binding success response matching
  /// any pending transaction id. Completes the waiter and returns the
  /// endpoint if matched; returns null otherwise.
  NatEndpoint? _tryParseStun(Uint8List data) {
    if (data.length < 20) return null;
    final bd = ByteData.sublistView(data);

    if (bd.getUint16(0) != _bindingSuccessResponse) return null;

    // Extract transaction id.
    final txId = <int>[];
    for (var i = 0; i < 12; i++) {
      txId.add(bd.getUint8(8 + i));
    }

    // Check if we have a pending waiter for this transaction id.
    final key = _txIdToKey(txId);
    final waiter = _pendingStun[key];
    if (waiter == null || waiter.isCompleted) return null;

    final length = bd.getUint16(2);
    final end = min(20 + length, data.length);
    var offset = 20;

    while (offset + 4 <= end) {
      final attrType = bd.getUint16(offset);
      final attrLen = bd.getUint16(offset + 2);
      final valueStart = offset + 4;
      if (valueStart + attrLen > data.length) break;

      if (attrType == _xorMappedAddress && attrLen >= 8) {
        if (data[valueStart + 1] == 0x01) {
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
    _pendingStun[_txIdToKey(txId)] = completer;

    try {
      socket.send(_buildBindingRequest(txId), server, _stunPort);
      return await completer.future.timeout(_stunTimeout, onTimeout: () => null);
    } finally {
      _pendingStun.remove(_txIdToKey(txId));
    }
  }

  /// Performs one STUN binding and updates the tracked endpoint. If the
  /// endpoint changed, fires [onEndpointChanged].
  Future<void> _tick() async {
    final result = await _bindOnce();
    if (result == null) return; // STUN unreachable — try again next tick.

    if (_currentEndpoint != result) {
      _currentEndpoint = result;
      // ignore: avoid_print
      print('[NAT-KEEPALIVE] Public UDP endpoint: ${result.hostPort}');
      onEndpointChanged?.call(result);
    }
  }

  /// Sole socket listener: dispatches STUN responses to pending waiters
  /// and everything else to [onIncomingDatagram].
  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;

    // Try to match as a STUN response first.
    final stunResult = _tryParseStun(dg.data);
    if (stunResult != null) {
      // Complete ALL pending waiters (there should be at most one matching,
      // but this is safe).
      for (final entry in _pendingStun.entries.toList()) {
        if (!entry.value.isCompleted) {
          entry.value.complete(stunResult);
        }
      }
      return;
    }

    // Not STUN — forward to the hole-punch handler.
    onIncomingDatagram?.call(dg);
  }

  /// Binds the UDP socket, resolves the STUN server, starts the sole
  /// listener, runs an initial probe, and starts the periodic timer.
  Future<void> start() async {
    if (_running) return;
    _running = true;

    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _stunServer ??= await _resolveIpv4(_stunHost);

    // Register as the SOLE listener on the socket.
    _socket!.listen(_onSocketEvent);

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
    _pendingStun.clear();
  }
}
