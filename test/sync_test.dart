import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/models/paired_device.dart';
import 'package:nexus_app/sync/knowledge_store.dart';
import 'package:nexus_app/sync/sync_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // NOTE: no TestWidgetsFlutterBinding here — it replaces HttpClient with a
  // mock that answers 400 to everything, which would break the real shelf
  // server used to exercise the sync exchange.

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// A sync engine bound to a real local HTTP server running [syncB]'s
  /// /sync handler, so syncWith() exercises the actual encrypted exchange.
  Future<(SyncService, HttpServer)> servePeer(
      SyncService peer, PairedDevice peerDevice) async {
    final handler = const Pipeline().addHandler(
      (request) => peer.handleSyncRequest(request, peerDevice),
    );
    final server =
        await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    return (peer, server);
  }

  group('KnowledgeStore.merge', () {
    test('merging a duplicate id changes nothing (idempotent)', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');
      final event = await store.addFact('Created a folder named "Notes"');
      expect(store.events, hasLength(1));

      // Same event arrives again (e.g. re-sync, or synced back from the peer).
      final newlyAdded = await store.merge([event]);
      expect(newlyAdded, isEmpty, reason: 'a duplicate id must not re-add');
      expect(store.events, hasLength(1));

      // Even a full re-merge of everything the store already has adds nothing.
      final again = await store.merge(store.events);
      expect(again, isEmpty);
      expect(store.events, hasLength(1));
    });

    test('eventsSince returns only events after the cursor', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');
      final first = await store.addFact('one');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await store.addFact('two');
      expect(store.eventsSince(first.createdAt).map((e) => e.id),
          isNot(contains(first.id)));
      expect(store.eventsSince(first.createdAt), hasLength(1));
    });
  });

  group('bidirectional exchange', () {
    test('both sides end up with the union of events', () async {
      final storeA = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');
      final storeB = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'B', deviceName: 'Phone');

      // Each side has events the other is missing.
      final remA = await storeA.addReminder(
          DateTime.now().add(const Duration(minutes: 5)), 'call Sam');
      final factB =
          await storeB.addFact('Created a folder named "Notes"');
      final remB = await storeB.addReminder(
          DateTime.now().add(const Duration(hours: 1)), 'water plants');

      // B's view of A and A's view of B share the same pairing key (as in a
      // real QR pairing, where both sides hold the same secret).
      final deviceB = PairedDevice(
        deviceId: 'B',
        deviceName: 'Phone',
        ipAddress: '127.0.0.1',
        port: 0,
        pairingKey: 'test-pair-key',
      );

      final scheduledOnB = <String>[];
      final scheduledOnA = <String>[];
      final syncB = SyncService(store: storeB)
        ..init(
          receivePort: 0,
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async => scheduledOnB.add(message),
        );
      final (_, server) = await servePeer(syncB, deviceB);

      final syncA = SyncService(store: storeA)
        ..init(
          receivePort: server.port,
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async => scheduledOnA.add(message),
        );

      final ok = await syncA.syncWith(deviceB);
      expect(ok, isTrue, reason: 'the peer is up, so the exchange must succeed');

      // Union on both sides, regardless of who created what.
      final expected = {remA.id, factB.id, remB.id};
      expect(storeA.events.map((e) => e.id).toSet(), expected);
      expect(storeB.events.map((e) => e.id).toSet(), expected);

      // Reminder propagation: B scheduled A's reminder; A scheduled B's.
      expect(scheduledOnB, contains('call Sam'));
      expect(scheduledOnA, contains('water plants'));
      // Facts are logged, not scheduled.
      expect(scheduledOnB, isNot(contains('Created a folder named "Notes"')));
    });

    test('a reminder event schedules exactly once even if synced twice',
        () async {
      final storeA = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');
      final storeB = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'B', deviceName: 'Phone');

      await storeA.addReminder(
          DateTime.now().add(const Duration(minutes: 5)), 'call Sam');

      final deviceB = PairedDevice(
        deviceId: 'B',
        deviceName: 'Phone',
        ipAddress: '127.0.0.1',
        port: 0,
        pairingKey: 'test-pair-key',
      );
      final scheduledOnB = <String>[];
      final syncB = SyncService(store: storeB)
        ..init(
          receivePort: 0,
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async => scheduledOnB.add(message),
        );
      final (_, server) = await servePeer(syncB, deviceB);

      final syncA = SyncService(store: storeA)
        ..init(
          receivePort: server.port,
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async {},
        );

      await syncA.syncWith(deviceB);
      expect(scheduledOnB, hasLength(1));

      // Syncing again sends nothing new and must not double-schedule.
      await syncA.syncWith(deviceB);
      expect(scheduledOnB, hasLength(1),
          reason: 'a duplicate sync must not fire the reminder twice');
    });

    test('a preference event syncs like reminders and facts', () async {
      final storeA = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');
      final storeB = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'B', deviceName: 'Phone');

      await storeA.addPreference('notify_device', 'B', valueName: 'Phone');
      final factB = await storeB.addFact('Created a folder named "Notes"');

      final deviceB = PairedDevice(
        deviceId: 'B',
        deviceName: 'Phone',
        ipAddress: '127.0.0.1',
        port: 0,
        pairingKey: 'test-pair-key',
      );
      final syncB = SyncService(store: storeB)
        ..init(
          receivePort: 0,
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async {},
        );
      final (_, server) = await servePeer(syncB, deviceB);
      final syncA = SyncService(store: storeA)
        ..init(
          receivePort: server.port,
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async {},
        );

      expect(await syncA.syncWith(deviceB), isTrue);

      // The preference reached B and B's fact reached A: the union holds.
      expect(storeB.currentPreference('notify_device')?.payload['value'], 'B');
      expect(storeB.currentPreference('notify_device')?.payload['valueName'],
          'Phone');
      expect(storeA.events.any((e) => e.id == factB.id), isTrue);
    });

    test('an unreachable peer fails gracefully and is not an error', () async {
      final storeA = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'A', deviceName: 'PC');
      final syncA = SyncService(store: storeA)
        ..init(
          receivePort: 1, // nothing is listening here
          devicesProvider: () async => const [],
          scheduleReminder: (when, message) async {},
        );
      final unreachable = PairedDevice(
        deviceId: 'B',
        deviceName: 'Phone',
        ipAddress: '127.0.0.1',
        port: 1,
        pairingKey: 'test-pair-key',
      );
      // Must return false, not throw — the caller (and the UI) treat a missed
      // sync as \"catch up next time\", never as a failure.
      expect(await syncA.syncWith(unreachable), isFalse);
    });
  });
}
