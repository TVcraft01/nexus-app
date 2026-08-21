import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/reminder_service.dart';
import '../models/paired_device.dart';
import '../pairing/pairing_service.dart';
import '../remote/remote_access_service.dart';
import '../tasks/task_crypto.dart';
import 'knowledge_store.dart';

/// Syncs the append-only knowledge log directly between paired devices.
///
/// No third-party server: each device POSTs its newer events (AES-GCM
/// encrypted with the same pairing-key-derived key as file transfer) to the
/// peer's local server, the peer merges them by id, and replies in the SAME
/// exchange with the events IT has that the sender is missing — so one request
/// performs the full bidirectional exchange. A device that's offline just
/// gets skipped; it catches up next time it's reachable (id-based merging
/// makes that safe — nothing is applied twice).
class SyncService {
  /// Shared by the whole app so there is one sync engine per device.
  static final SyncService instance = SyncService();

  static final ReminderService _realReminders = ReminderService();

  /// The log this engine reads from and merges into. Tests inject isolated
  /// stores to verify the exchange without touching the app-wide singleton.
  final KnowledgeStore _store;

  SyncService({KnowledgeStore? store}) : _store = store ?? KnowledgeStore.instance;

  int _receivePort = 0;
  Future<List<PairedDevice>> Function()? _devicesProvider;
  bool _initialized = false;

  /// Injectable so tests can assert that arriving reminder events schedule a
  /// real notification. Defaults to the real on-device [ReminderService].
  Future<void> Function(DateTime when, String message) _scheduleReminder =
      (when, message) => _realReminders.scheduleReminder(when, message);

  /// Per-peer sync cursor, stored as `nexus_sync_cursor_<deviceId>`.
  static const _cursorKeyPrefix = 'nexus_sync_cursor_';

  /// Wire up dependencies. Called once at app start. [receivePort] is the
  /// local transfer server's port (the same one file transfer uses).
  void init({
    required int receivePort,
    required Future<List<PairedDevice>> Function() devicesProvider,
    Future<void> Function(DateTime when, String message)? scheduleReminder,
  }) {
    _receivePort = receivePort;
    _devicesProvider = devicesProvider;
    if (scheduleReminder != null) _scheduleReminder = scheduleReminder;
    _initialized = true;
  }

  // ---- receiving side -----------------------------------------------------

  /// Handles an incoming /sync request from [device] (already authenticated by
  /// the pairing key). Merges the sender's events and returns, in the response
  /// body, the events this device has that the sender is missing — one
  /// encrypted exchange, both directions.
  Future<Response> handleSyncRequest(
    Request request,
    PairedDevice device,
  ) async {
    final store = _store;
    try {
      final keyBytes = base64Decode(device.transferKey);
      final encrypted = await request.read().expand((chunk) => chunk).toList();
      final plain = await decryptTaskPayload(encrypted, keyBytes);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;

      final since = DateTime.tryParse(json['since'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final incoming = [
        for (final e in json['events'] as List? ?? const [])
          KnowledgeEvent.fromJson(e as Map<String, dynamic>),
      ];

      // Id-based merge: duplicates are ignored, so re-syncing changes nothing.
      final newlyAdded = await store.merge(incoming);
      await _scheduleIncomingReminders(newlyAdded);

      // Reply with everything the sender is missing (events after its cursor).
      final outbound = store.eventsSince(since);
      // Piggyback this device's public UDP endpoint so the peer can
      // hole-punch later when not on the same LAN.
      final udp = RemoteAccessService.instance.publicUdpEndpoint;
      final responsePayload = utf8.encode(jsonEncode({
        'events': [for (final e in outbound) e.toJson()],
        if (udp != null) 'publicUdpEndpoint': udp.hostPort,
      }));
      return Response.ok(
        await encryptTaskPayload(responsePayload, keyBytes),
        headers: {'content-type': 'application/octet-stream'},
      );
    } catch (e) {
      return Response.badRequest(
        body: jsonEncode({'error': 'sync failed: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  // ---- sending side -------------------------------------------------------

  /// One full bidirectional sync with [device]. Returns true when the exchange
  /// completed. Never throws for an unreachable/failing peer — sync is
  /// best-effort and just catches up next time.
  Future<bool> syncWith(PairedDevice device) async {
    if (!_initialized) return false;
    final store = _store;
    try {
      final since = await _cursorFor(device.deviceId);
      final outbound = store.eventsSince(since);
      final keyBytes = base64Decode(device.transferKey);
      final payload = utf8.encode(jsonEncode({
        'since': since.toIso8601String(),
        'events': [for (final e in outbound) e.toJson()],
      }));
      final encrypted = await encryptTaskPayload(payload, keyBytes);

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      try {
        final request = await client.postUrl(
          Uri.parse('http://${device.ipAddress}:$_receivePort/sync'),
        );
        request.headers.set('content-type', 'application/octet-stream');
        request.headers.set('x-nexus-key', device.authToken);
        request.add(encrypted);
        final response = await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          await response.drain<void>();
          return false;
        }
        final body =
            await response.expand((chunk) => chunk).toList().timeout(const Duration(seconds: 10));
        final plain = await decryptTaskPayload(body, keyBytes);
        final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        final incoming = [
          for (final e in json['events'] as List? ?? const [])
            KnowledgeEvent.fromJson(e as Map<String, dynamic>),
        ];
        final newlyAdded = await store.merge(incoming);
        await _scheduleIncomingReminders(newlyAdded);

        // The peer may have piggybacked its public UDP endpoint so we can
        // hole-punch later when not on the same LAN.
        final peerUdp = json['publicUdpEndpoint'] as String?;
        if (peerUdp != null && peerUdp.isNotEmpty) {
          await PairingService()
              .updateDevicePublicUdpEndpoint(device.deviceId, peerUdp);
        }

        // Advance this peer's cursor so next time we only send what's new.
        await _setCursor(device.deviceId, DateTime.now().toUtc());
        return true;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return false;
    }
  }

  /// Best-effort sync with every paired device. Offline peers are skipped
  /// silently (they catch up next time); returns how many exchanges succeeded.
  Future<int> syncAll() async {
    if (!_initialized) return 0;
    final devices = await _devicesProvider?.call() ?? const <PairedDevice>[];
    var succeeded = 0;
    for (final device in devices) {
      if (await syncWith(device)) succeeded++;
    }
    return succeeded;
  }

  /// A reminder event arriving from another device should actually fire on
  /// this one — not just be stored. Only newly-merged events are scheduled, so
  /// a duplicate sync never double-schedules.
  Future<void> _scheduleIncomingReminders(List<KnowledgeEvent> newlyAdded) async {
    for (final event in newlyAdded) {
      if (event.type != KnowledgeEventType.reminder) continue;
      final when = DateTime.tryParse(event.payload['when'] as String? ?? '');
      if (when == null) continue;
      await _scheduleReminder(when.toLocal(), event.payload['message'] as String? ?? 'Reminder');
    }
  }

  // ---- cursors ------------------------------------------------------------

  Future<DateTime> _cursorFor(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_cursorKeyPrefix$deviceId');
    return DateTime.tryParse(raw ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _setCursor(String deviceId, DateTime cursor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_cursorKeyPrefix$deviceId', cursor.toIso8601String());
  }
}
