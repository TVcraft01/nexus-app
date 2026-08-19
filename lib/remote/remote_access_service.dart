import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../pairing/pairing_service.dart';
import '../settings/settings_service.dart';
import 'nat_keepalive.dart';
import 'port_mapper.dart';
import 'stun_client.dart';
import 'udp_receive_server.dart';

/// How a paired device was last reached (or not).
enum DeviceLinkStatus { unknown, local, remote, remoteUdp, unreachable }

/// Drives the opt-in "reach my devices over the internet" feature.
///
/// When the "Allow internet access" setting is ON, this periodically:
///   1. discovers this device's public IP via STUN, and
///   2. tries to open a public TCP port mapping (UPnP IGD, then NAT-PMP) so a
///      paired device on another network can reach our local receive server.
///
/// It is a [ChangeNotifier] so the Settings screen can show live per-device
/// status (Local / Remote / Unreachable) and the current public endpoint.
///
/// Everything here is direct device-to-device: STUN sees only connection
/// metadata (never file bytes, commands, or messages), and the router mapping
/// only exposes our own port. No third-party server relays user data.
class RemoteAccessService extends ChangeNotifier {
  static final RemoteAccessService instance = RemoteAccessService._();

  RemoteAccessService._();

  final SettingsService _settings = SettingsService();
  final StunClient _stun = StunClient();
  final PortMapper _mapper = PortMapper();
  final NatKeepAlive _keepAlive = NatKeepAlive();
  final UdpReceiveServer _udpServer = UdpReceiveServer();

  bool _enabled = false;
  String? _publicAddress; // "ip:port" when a TCP mapping is open
  String? _publicIp; // from STUN, even when no mapping could be opened
  int _receivePort = 51821;
  final Map<String, DeviceLinkStatus> _statuses = {};
  Timer? _refreshTimer;

  bool get enabled => _enabled;

  /// `ip:port` a peer can use to reach us remotely (TCP path), or null when
  /// no mapping is currently open.
  String? get publicAddress => _publicAddress;

  /// Our public IP as seen by STUN (informational).
  String? get publicIp => _publicIp;

  /// The public UDP endpoint discovered by NAT keep-alive, or null.
  NatEndpoint? get publicUdpEndpoint => _keepAlive.endpoint;

  /// The UDP socket kept alive for hole-punch traffic.
  RawDatagramSocket? get udpSocket => _keepAlive.socket;

  DeviceLinkStatus statusOf(String deviceId) =>
      _statuses[deviceId] ?? DeviceLinkStatus.unknown;

  Future<void> init() async {
    // Just read the stored setting; don't set [_enabled] here so that
    // the caller can use [setEnabled] to activate everything (including
    // NAT keep-alive) without hitting the early-return guard.
  }

  /// Toggles the feature. When turned on it immediately opens a mapping; when
  /// turned off it releases the mapping and forgets remote status.
  Future<void> setEnabled(bool value) async {
    await _settings.setAllowInternetAccess(value);
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      try {
        await refreshPublicAddress();
      } catch (_) {
        // UPnP failure is expected; keep-alive still works.
      }
      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        refreshPublicAddress();
      });
      // Start NAT keep-alive: holds a UDP socket open with periodic STUN
      // probes so home routers don't evict the mapping. When the endpoint
      // changes, share it with paired devices.
      _keepAlive.onEndpointChanged = (ep) => _shareUdpEndpoint(ep);
      await _keepAlive.start();
      _udpServer.start(_keepAlive);
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      await _keepAlive.stop();
      await _release();
      _statuses.clear();
    }
    notifyListeners();
  }

  /// Re-discovers the public IP and (re)opens the TCP mapping for
  /// [receivePort]. Safe to call whenever connectivity changes.
  Future<void> refreshPublicAddress({int? receivePort}) async {
    if (receivePort != null) _receivePort = receivePort;
    if (!_enabled) return;

    _publicIp = (await _stun.discover())?.publicIp;
    final mapped = await _mapper.mapTcpPort(_receivePort);
    _publicAddress = mapped == null
        ? null
        : '${mapped.publicIp}:${mapped.externalPort}';
    notifyListeners();
  }

  /// Records how a device was last reached, so Settings shows live status.
  void reportStatus(String deviceId, DeviceLinkStatus status) {
    if (_statuses[deviceId] != status) {
      _statuses[deviceId] = status;
      notifyListeners();
    }
  }

  /// Shares the current public UDP endpoint with all paired devices so they
  /// can attempt hole-punching later. Called whenever the endpoint changes.
  void _shareUdpEndpoint(NatEndpoint ep) {
    final pairing = PairingService();
    pairing.getPairedDevices().then((devices) {
      for (final d in devices) {
        pairing.updateDevicePublicUdpEndpoint(d.deviceId, ep.hostPort);
      }
    });
    notifyListeners();
  }

  Future<void> _release() async {
    if (_publicAddress != null) {
      final port = int.tryParse(_publicAddress!.split(':').last) ?? _receivePort;
      await _mapper.releaseTcpPort(_receivePort, port);
    }
    _publicAddress = null;
    _publicIp = null;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
