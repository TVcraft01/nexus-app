import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// What kind of knowledge an event carries. Every kind is append-only — an
/// event is created once, given an id that never changes, and never edited.
enum KnowledgeEventType { reminder, fact, preference }

/// The retention rules [KnowledgeStore.prune] applies so the append-only log
/// does not grow unbounded forever.
///
/// For each type the store keeps everything within a window AND at least the
/// most recent N events of that type (whichever is more). Reminders are the
/// exception: a reminder that has not fired yet is always kept (pruning must
/// never drop something the user is still waiting for), and *fired* reminders
/// are pruned more aggressively than facts/preferences. The latest event for
/// each preference key is also always kept, because that event defines the
/// current behaviour (e.g. "notify only on this device").
class KnowledgeRetentionPolicy {
  final Duration factWindow;
  final Duration preferenceWindow;
  final Duration reminderFiredWindow;
  final int minFacts;
  final int minPreferences;
  final int minReminders;

  const KnowledgeRetentionPolicy({
    this.factWindow = const Duration(days: 90),
    this.preferenceWindow = const Duration(days: 90),
    this.reminderFiredWindow = const Duration(days: 30),
    this.minFacts = 200,
    this.minPreferences = 200,
    this.minReminders = 20,
  });

  static const defaults = KnowledgeRetentionPolicy();
}

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
  static const _tombstonesKey = 'nexus_knowledge_tombstones';

  /// How long a pruned event's id is remembered as "already seen", so a peer
  /// that hasn't pruned yet can't resurrect it by syncing it back to us. Long
  /// enough to outlive the longest retention window (90 days) with slack; once
  /// it expires, the only thing that can come back is an event old enough that
  /// a past reminder won't re-fire and a stale fact is a harmless wart.
  static const tombstoneTtl = Duration(days: 180);

  /// Shared by the whole app (the Talk tab records events, sync both sends
  /// and merges them) so there is exactly one log per device.
  static final KnowledgeStore instance = KnowledgeStore();

  final Uuid _uuid = const Uuid();
  final List<KnowledgeEvent> _events = [];
  final Map<String, DateTime> _tombstones = {};

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
    // Ensure this device has a stable id even before its first pairing, so
    // preference checks that compare against it can rely on it being set.
    if (_deviceId.isEmpty) {
      _deviceId = _uuid.v4();
      await prefs.setString(_deviceIdKey, _deviceId);
    }
    _deviceName = prefs.getString(_deviceNameKey) ?? 'This device';
    final raw = prefs.getStringList(_eventsKey) ?? [];
    _events
      ..clear()
      ..addAll(raw.map((r) => KnowledgeEvent.fromJson(jsonDecode(r) as Map<String, dynamic>)));
    final rawTombstones = prefs.getStringList(_tombstonesKey) ?? [];
    _tombstones
      ..clear()
      ..addEntries(rawTombstones.map((r) {
        final j = jsonDecode(r) as Map<String, dynamic>;
        return MapEntry(
          j['id'] as String,
          DateTime.parse(j['prunedAt'] as String),
        );
      }));
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

  /// Records a learned preference. [key] names the preference (e.g.
  /// "notify_device"), [value] is its value (for notify_device, the deviceId
  /// that should receive notifications — empty means "all devices").
  /// [valueName] is a human-readable label for display; the id is what gets
  /// compared at fire time, but a name survives a device being renamed.
  ///
  /// Preferences are append-only like everything else: "changing" a preference
  /// adds a newer event, and the latest one for a key wins.
  Future<KnowledgeEvent> addPreference(
    String key,
    String value, {
    String? valueName,
  }) =>
      addEvent(KnowledgeEventType.preference, {
        'key': key,
        'value': value,
        if (valueName != null && valueName.isNotEmpty) 'valueName': valueName,
      });

  /// The most recent preference event for [key], or null if none exists.
  KnowledgeEvent? currentPreference(String key) {
    for (final e in _events.reversed) {
      if (e.type == KnowledgeEventType.preference &&
          e.payload['key'] == key) {
        return e;
      }
    }
    return null;
  }

  /// Whether a reminder firing on THIS device should actually show a local
  /// notification, given the current "notify_device" preference.
  ///
  /// True (fire) when no preference is set or it was cleared — the opt-in
  /// default is unchanged: every device notifies. False (skip) only when a
  /// preference targets a DIFFERENT device id. The reminder still lives in the
  /// shared log on this device either way; it just doesn't interrupt here.
  bool shouldNotifyLocally() {
    final pref = currentPreference('notify_device');
    if (pref == null) return true;
    final value = pref.payload['value'] as String? ?? '';
    if (value.isEmpty) return true;
    return value == deviceId;
  }

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

  /// Test-only: adds an event with an explicit creation time/id, so pruning
  /// tests can build a deterministic "old vs recent" log without sleeping.
  @visibleForTesting
  Future<KnowledgeEvent> debugAddEvent({
    required KnowledgeEventType type,
    required Map<String, dynamic> payload,
    required DateTime createdAt,
    String? id,
  }) async {
    final event = KnowledgeEvent(
      id: id ?? _uuid.v4(),
      type: type,
      payload: payload,
      originDeviceId: _deviceId,
      originDeviceName: _deviceName,
      createdAt: createdAt.toUtc(),
    );
    _events.add(event);
    await _persist();
    notifyListeners();
    return event;
  }

  /// Prunes the log according to [policy] and returns how many events were
  /// removed.
  ///
  /// Pruning is LOCAL ONLY: it never changes what a peer stores, and it never
  /// changes when a still-pending reminder fires. To keep the sync-idempotency
  /// guarantee, every pruned id is remembered in a bounded tombstone set, so
  /// if a peer that hasn't pruned yet sends the same event back to us, [merge]
  /// ignores it instead of treating it as new (which would re-schedule an
  /// already-fired reminder).
  Future<int> prune({
    DateTime? now,
    KnowledgeRetentionPolicy policy = KnowledgeRetentionPolicy.defaults,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final keepIds = <String>{};

    final reminders = _events
        .where((e) => e.type == KnowledgeEventType.reminder)
        .toList();
    final fired = <KnowledgeEvent>[];
    for (final e in reminders) {
      final when = DateTime.tryParse(e.payload['when'] as String? ?? '');
      if (when == null || !when.isAfter(at)) {
        fired.add(e);
      } else {
        keepIds.add(e.id); // never prune a reminder that hasn't fired
      }
    }
    _addRetained(fired, keepIds, at,
        policy.reminderFiredWindow, policy.minReminders);

    _addRetained(
      _events.where((e) => e.type == KnowledgeEventType.fact).toList(),
      keepIds,
      at,
      policy.factWindow,
      policy.minFacts,
    );

    final preferences = _events
        .where((e) => e.type == KnowledgeEventType.preference)
        .toList();
    _addRetained(preferences, keepIds, at,
        policy.preferenceWindow, policy.minPreferences);
    // The latest event per preference key defines current behaviour, so it is
    // always kept even when it is older than the window.
    final seenKeys = <String>{};
    for (final e in preferences.reversed) {
      final key = e.payload['key'] as String? ?? '';
      if (seenKeys.add(key)) keepIds.add(e.id);
    }

    final before = _events.length;
    final pruned = <KnowledgeEvent>[];
    final kept = <KnowledgeEvent>[];
    for (final e in _events) {
      (keepIds.contains(e.id) ? kept : pruned).add(e);
    }
    _events
      ..clear()
      ..addAll(kept);

    final tombstoneCountBefore = _tombstones.length;
    for (final e in pruned) {
      _tombstones[e.id] = at;
    }
    _expireTombstones(at);

    if (pruned.isNotEmpty) await _persist();
    if (_tombstones.length != tombstoneCountBefore) {
      await _persistTombstones();
    }
    if (before != _events.length) notifyListeners();
    return pruned.length;
  }

  void _addRetained(
    List<KnowledgeEvent> events,
    Set<String> keepIds,
    DateTime now,
    Duration window,
    int minCount,
  ) {
    final cutoff = now.subtract(window);
    for (final e in events) {
      if (e.createdAt.isAfter(cutoff)) keepIds.add(e.id);
    }
    final byNewest = events.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final e in byNewest.take(minCount)) {
      keepIds.add(e.id);
    }
  }

  void _expireTombstones(DateTime now) {
    final cutoff = now.subtract(tombstoneTtl);
    _tombstones.removeWhere((_, prunedAt) => prunedAt.isBefore(cutoff));
  }

  /// Events created strictly after [since] — what a peer missing our newer
  /// events should receive. An append-only log makes this exact.
  List<KnowledgeEvent> eventsSince(DateTime since) =>
      _events.where((e) => e.createdAt.isAfter(since)).toList();

  /// Merges [incoming] events by id: anything already present is ignored,
  /// anything new is appended. Returns the newly-added events so the caller
  /// can act on them once (e.g. schedule a reminder notification). Idempotent:
  /// merging the same set twice returns nothing the second time.
  ///
  /// An event id in the tombstone set (pruned locally) is ALSO ignored: a
  /// peer that hasn't pruned yet may legitimately send it back, and it must
  /// not be treated as "new" again — otherwise pruning would resurrect old
  /// reminders and re-schedule them.
  Future<List<KnowledgeEvent>> merge(List<KnowledgeEvent> incoming) async {
    final added = <KnowledgeEvent>[];
    for (final event in incoming) {
      if (hasEvent(event.id)) continue;
      if (_tombstones.containsKey(event.id)) continue;
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

  Future<void> _persistTombstones() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _tombstonesKey,
      [
        for (final e in _tombstones.entries)
          jsonEncode({'id': e.key, 'prunedAt': e.value.toIso8601String()}),
      ],
    );
  }
}
