import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/settings_service.dart';
import 'port_mapper.dart';
import 'stun_client.dart';

/// How a paired device was last reached (or not).
enum DeviceLinkStatus { unknown, local, remote, unreachable }

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

  bool _enabled = false;
  String? _publicAddress; // "ip:port" when a TCP mapping is open
  String? _publicIp; // from STUN, even when no mapping could be opened
  int _receivePort = 51821;
  final Map<String, DeviceLinkStatus> _statuses = {};
  Timer? _refreshTimer;

  bool get enabled => _enabled;

  /// `ip:port` a peer can use to reach us remotely, or null when no mapping is
  /// currently open.
  String? get publicAddress => _publicAddress;

  /// Our public IP as seen by STUN (informational).
  String? get publicIp => _publicIp;

  DeviceLinkStatus statusOf(String deviceId) =>
      _statuses[deviceId] ?? DeviceLinkStatus.unknown;

  Future<void> init() async {
    _enabled = await _settings.getAllowInternetAccess();
  }

  /// Toggles the feature. When turned on it immediately opens a mapping; when
  /// turned off it releases the mapping and forgets remote status.
  Future<void> setEnabled(bool value) async {
    await _settings.setAllowInternetAccess(value);
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      await refreshPublicAddress();
      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        refreshPublicAddress();
      });
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
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
