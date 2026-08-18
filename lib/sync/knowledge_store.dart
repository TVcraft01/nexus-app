import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// What kind of knowledge an event carries. Both kinds are append-only — an
/// event is created once, given an id that never changes, and never edited.
enum KnowledgeEventType { reminder, fact }

/// One entry in the append-only knowledge log.
///
/// `id` is generated once at creation and never changes. That single fact is
/// what makes merging between devices idempotent: a device receiving an event
/// it already has (same id) simply ignores it, so syncing twice — or syncing
/// an event back to the device that created it — changes nothing.
class KnowledgeEvent {
  final String id;
  final KnowledgeEventType type;
  final Map<String, dynamic> payload;
  final String originDeviceId;
  final String originDeviceName;
  final DateTime createdAt;

  const KnowledgeEvent({
    required this.id,
    required this.type,
    required this.payload,
    required this.originDeviceId,
    required this.originDeviceName,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'payload': payload,
        'originDeviceId': originDeviceId,
        'originDeviceName': originDeviceName,
        'createdAt': createdAt.toIso8601String(),
      };

  factory KnowledgeEvent.fromJson(Map<String, dynamic> json) => KnowledgeEvent(
        id: json['id'] as String,
        type: KnowledgeEventType.values.byName(json['type'] as String),
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        originDeviceId: json['originDeviceId'] as String? ?? '',
        originDeviceName: json['originDeviceName'] as String? ?? 'Unknown',
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

/// The local, append-only knowledge log shared between paired devices.
///
/// Stores events as a JSON list in SharedPreferences (the same pattern as the
/// paired-devices list and transfer history). Extends [ChangeNotifier] so the
/// "Known facts" screen rebuilds as events arrive.
class KnowledgeStore extends ChangeNotifier {
  static const _eventsKey = 'nexus_knowledge_events';
  static const _deviceIdKey = 'nexus_device_id';
  static const _deviceNameKey = 'nexus_device_name';

  /// Shared by the whole app (the Talk tab records events, sync both sends
  /// and merges them) so there is exactly one log per device.
  static final KnowledgeStore instance = KnowledgeStore();

  final Uuid _uuid = const Uuid();
  final List<KnowledgeEvent> _events = [];

  String _deviceId = '';
  String _deviceName = '';

  /// All events in creation order (oldest first).
  List<KnowledgeEvent> get events => List.unmodifiable(_events);

  /// Events newest-first, for display.
  List<KnowledgeEvent> get eventsNewestFirst =>
      List.unmodifiable(_events.reversed);

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;

  /// Test-only: set this device's identity without touching prefs, so two
  /// isolated stores can pretend to be different devices in one test.
  @visibleForTesting
  void debugSetIdentity({required String deviceId, required String deviceName}) {
    _deviceId = deviceId;
    _deviceName = deviceName;
  }

  /// Loads the persisted log and this device's identity. Call once at startup.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_deviceIdKey) ?? '';
    _deviceName = prefs.getString(_deviceNameKey) ?? 'This device';
    final raw = prefs.getStringList(_eventsKey) ?? [];
    _events
      ..clear()
      ..addAll(raw.map((r) => KnowledgeEvent.fromJson(jsonDecode(r) as Map<String, dynamic>)));
    notifyListeners();
  }

  bool hasEvent(String id) => _events.any((e) => e.id == id);

  /// Records a reminder event, originated on this device. The time is stored
  /// as UTC so the absolute moment survives syncing to a device in another
  /// timezone.
  Future<KnowledgeEvent> addReminder(DateTime when, String message) =>
      addEvent(KnowledgeEventType.reminder, {
        'when': when.toUtc().toIso8601String(),
        'message': message,
      });

  /// Records a fact (a short note the assistant picked up), originated on this
  /// device. Honest by construction: facts are only what the app itself logs,
  /// e.g. \"user asked to create a folder named X\" — never invented learning.
  Future<KnowledgeEvent> addFact(String text) =>
      addEvent(KnowledgeEventType.fact, {'text': text});

  Future<KnowledgeEvent> addEvent(
    KnowledgeEventType type,
    Map<String, dynamic> payload,
  ) async {
    final event = KnowledgeEvent(
      id: _uuid.v4(),
      type: type,
      payload: payload,
      originDeviceId: _deviceId,
      originDeviceName: _deviceName,
      createdAt: DateTime.now().toUtc(),
    );
    _events.add(event);
    await _persist();
    notifyListeners();
    return event;
  }

  /// Events created strictly after [since] — what a peer missing our newer
  /// events should receive. An append-only log makes this exact.
  List<KnowledgeEvent> eventsSince(DateTime since) =>
      _events.where((e) => e.createdAt.isAfter(since)).toList();

  /// Merges [incoming] events by id: anything already present is ignored,
  /// anything new is appended. Returns the newly-added events so the caller
  /// can act on them once (e.g. schedule a reminder notification). Idempotent:
  /// merging the same set twice returns nothing the second time.
  Future<List<KnowledgeEvent>> merge(List<KnowledgeEvent> incoming) async {
    final added = <KnowledgeEvent>[];
    for (final event in incoming) {
      if (hasEvent(event.id)) continue;
      _events.add(event);
      added.add(event);
    }
    if (added.isNotEmpty) {
      await _persist();
      notifyListeners();
    }
    return added;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _eventsKey,
      [for (final e in _events) jsonEncode(e.toJson())],
    );
  }
}
