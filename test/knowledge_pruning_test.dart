import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/sync/knowledge_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  KnowledgeStore store() => KnowledgeStore()
    ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');

  group('KnowledgeStore.prune — retention rules', () {
    test('keeps recent facts and prunes only what is beyond the window+floor',
        () async {
      final s = store();
      final now = DateTime.now().toUtc();
      final old = now.subtract(const Duration(days: 200));
      const policy = KnowledgeRetentionPolicy(
        factWindow: Duration(days: 90),
        minFacts: 1,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'old fact'},
        createdAt: old,
      );
      await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'recent fact'},
        createdAt: now,
      );

      final pruned = await s.prune(now: now, policy: policy);
      expect(pruned, 1);
      expect(s.events.map((e) => e.payload['text']), ['recent fact']);
    });

    test('keeps the most recent N facts even when older than the window',
        () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        factWindow: Duration(days: 1),
        minFacts: 2,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'oldest'},
        createdAt: now.subtract(const Duration(days: 10)),
      );
      await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'older'},
        createdAt: now.subtract(const Duration(days: 5)),
      );
      await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'recent'},
        createdAt: now,
      );

      final pruned = await s.prune(now: now, policy: policy);
      expect(pruned, 1);
      expect(s.events.map((e) => e.payload['text']), ['older', 'recent']);
    });

    test('never prunes a reminder that has not fired yet, however old', () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        reminderFiredWindow: Duration(days: 1),
        minReminders: 0,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.reminder,
        payload: {
          'when': now.add(const Duration(hours: 1)).toIso8601String(),
          'message': 'still pending',
        },
        createdAt: now.subtract(const Duration(days: 400)),
      );

      expect(await s.prune(now: now, policy: policy), 0);
      expect(s.events, hasLength(1));
    });

    test('prunes fired reminders more aggressively than facts', () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        reminderFiredWindow: Duration(days: 30),
        minReminders: 0,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.reminder,
        payload: {
          'when': now.subtract(const Duration(days: 60)).toIso8601String(),
          'message': 'fired long ago',
        },
        createdAt: now.subtract(const Duration(days: 60)),
      );

      expect(await s.prune(now: now, policy: policy), 1);
      expect(s.events, isEmpty);
    });

    test('keeps the latest event per preference key even when old', () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        preferenceWindow: Duration(days: 1),
        minPreferences: 0,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.preference,
        payload: {'key': 'notify_device', 'value': 'phone'},
        createdAt: now.subtract(const Duration(days: 300)),
      );

      expect(await s.prune(now: now, policy: policy), 0);
      expect(s.currentPreference('notify_device')?.payload['value'], 'phone');
    });

    test('prunes an older preference event once a newer one for the key exists',
        () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        preferenceWindow: Duration(days: 1),
        minPreferences: 0,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.preference,
        payload: {'key': 'notify_device', 'value': 'phone'},
        createdAt: now.subtract(const Duration(days: 300)),
      );
      await s.debugAddEvent(
        type: KnowledgeEventType.preference,
        payload: {'key': 'notify_device', 'value': 'pc'},
        createdAt: now,
      );

      expect(await s.prune(now: now, policy: policy), 1);
      expect(s.currentPreference('notify_device')?.payload['value'], 'pc');
    });
  });

  group('pruning does not break sync idempotency', () {
    test('a pruned event id arriving via sync is not treated as new', () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        factWindow: Duration(days: 1),
        minFacts: 0,
      );

      final event = await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'old'},
        createdAt: now.subtract(const Duration(days: 100)),
      );
      await s.prune(now: now, policy: policy);
      expect(s.events, isEmpty);

      // A peer that hasn't pruned yet sends the same event back.
      final added = await s.merge([event]);
      expect(added, isEmpty);
      expect(s.events, isEmpty,
          reason: 'a tombstoned id must stay pruned, not resurrect');
    });

    test('tombstones are persisted, so a fresh store still ignores the id',
        () async {
      final s1 = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        factWindow: Duration(days: 1),
        minFacts: 0,
      );

      final event = await s1.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'old'},
        createdAt: now.subtract(const Duration(days: 100)),
      );
      await s1.prune(now: now, policy: policy);

      // A fresh store reading the same (mock) prefs — as after an app restart.
      final s2 = store();
      await s2.init();
      final added = await s2.merge([event]);
      expect(added, isEmpty);
      expect(s2.events, isEmpty);
    });

    test('a genuinely new id is still merged after pruning', () async {
      final s = store();
      final now = DateTime.now().toUtc();
      const policy = KnowledgeRetentionPolicy(
        factWindow: Duration(days: 1),
        minFacts: 0,
      );

      await s.debugAddEvent(
        type: KnowledgeEventType.fact,
        payload: {'text': 'old'},
        createdAt: now.subtract(const Duration(days: 100)),
      );
      await s.prune(now: now, policy: policy);

      final fromPeer = KnowledgeEvent(
        id: 'brand-new-id',
        type: KnowledgeEventType.fact,
        payload: const {'text': 'from peer'},
        originDeviceId: 'B',
        originDeviceName: 'Phone',
        createdAt: now,
      );
      final added = await s.merge([fromPeer]);
      expect(added, hasLength(1),
          reason: 'pruning must not block new, never-seen events');
      expect(s.events.single.id, 'brand-new-id');
    });
  });
}
