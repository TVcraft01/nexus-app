import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/keyword_brain.dart';
import 'package:nexus_app/ai/nexus_action_runner.dart';
import 'package:nexus_app/ai/nexus_brain.dart';
import 'package:nexus_app/models/paired_device.dart';
import 'package:nexus_app/sync/knowledge_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

PairedDevice _device(
  String id,
  String name, {
  String? platform,
}) =>
    PairedDevice(
      deviceId: id,
      deviceName: name,
      ipAddress: '127.0.0.1',
      port: 1,
      pairingKey: 'test-key',
      platform: platform,
    );

void main() {
  // NexusActionRunner constructs FlutterTts, which registers a method-channel
  // handler; the widget binding must exist before that happens.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('resolveDeviceReference', () {
    final phone = _device('p1', 'My Phone', platform: 'android');
    final tablet = _device('p2', 'My Tablet', platform: 'android');
    final pc = _device('c1', 'My PC', platform: 'linux');
    final all = [phone, tablet, pc];

    test('maps "phone" to Android devices only', () {
      expect(resolveDeviceReference('phone', all), [phone, tablet]);
    });

    test('maps "pc"/"laptop"/"computer" to desktop devices only', () {
      expect(resolveDeviceReference('pc', all), [pc]);
      expect(resolveDeviceReference('laptop', all), [pc]);
      expect(resolveDeviceReference('computer', all), [pc]);
    });

    test('an unknown reference matches nothing', () {
      expect(resolveDeviceReference('watch', all), isEmpty);
    });

    test('legacy device without a platform falls back to its name', () {
      final legacy = _device('old', 'android', platform: null);
      expect(legacy.isPhone, isTrue);
      expect(legacy.isComputer, isFalse);
      final desktop = _device('old2', 'linux', platform: null);
      expect(desktop.isComputer, isTrue);
    });
  });

  group('KnowledgeStore.shouldNotifyLocally', () {
    test('defaults to firing on every device when no preference is set',
        () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      expect(store.shouldNotifyLocally(), isTrue);
    });

    test('respects a preference targeting a different device', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      await store.addPreference('notify_device', 'phone-id',
          valueName: 'Phone');
      expect(store.shouldNotifyLocally(), isFalse,
          reason: 'the PC is not the chosen notify device');
    });

    test('fires when the preference targets this device', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      await store.addPreference('notify_device', 'pc', valueName: 'PC');
      expect(store.shouldNotifyLocally(), isTrue);
    });

    test('a cleared (empty) preference returns to fire-everywhere', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      await store.addPreference('notify_device', 'phone-id',
          valueName: 'Phone');
      expect(store.shouldNotifyLocally(), isFalse);
      await store.addPreference('notify_device', '');
      expect(store.shouldNotifyLocally(), isTrue);
    });
  });

  group('NexusActionRunner.setPreference', () {
    test('a single matching device resolves and stores the preference',
        () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      final phone = _device('phone-id', 'My Phone', platform: 'android');
      final runner = NexusActionRunner(
        store: store,
        devicesProvider: () async => [phone],
      );

      final reply = await runner.run(const NexusAction(
        command: NexusCommand.setPreference,
        reply: 'Got it.',
        args: {'key': 'notify_device', 'deviceRef': 'phone'},
      ));

      expect(reply, contains('My Phone'));
      expect(runner.awaitingClarification, isFalse);
      final pref = store.currentPreference('notify_device');
      expect(pref, isNotNull);
      expect(pref!.payload['value'], 'phone-id');
      expect(pref.payload['valueName'], 'My Phone');
    });

    test('an ambiguous reference asks instead of guessing', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      final phoneA = _device('p1', 'Sam Phone', platform: 'android');
      final phoneB = _device('p2', 'Work Phone', platform: 'android');
      final runner = NexusActionRunner(
        store: store,
        devicesProvider: () async => [phoneA, phoneB],
      );

      final reply = await runner.run(const NexusAction(
        command: NexusCommand.setPreference,
        reply: 'Got it.',
        args: {'key': 'notify_device', 'deviceRef': 'phone'},
      ));

      expect(reply, contains('Which device'));
      expect(reply, contains('Sam Phone'));
      expect(reply, contains('Work Phone'));
      expect(runner.awaitingClarification, isTrue);
      // Nothing stored yet — the question must be answered first.
      expect(store.currentPreference('notify_device'), isNull);

      final answer = await runner.answerClarification('Sam Phone');
      expect(answer, contains('Sam Phone'));
      expect(runner.awaitingClarification, isFalse);
      expect(store.currentPreference('notify_device')!.payload['value'],
          phoneA.deviceId);
    });

    test('no matching device produces a helpful reply, not a guess', () async {
      final store = KnowledgeStore()
        ..debugSetIdentity(deviceId: 'pc', deviceName: 'PC');
      final runner = NexusActionRunner(
        store: store,
        devicesProvider: () async => const [],
      );

      final reply = await runner.run(const NexusAction(
        command: NexusCommand.setPreference,
        reply: 'Got it.',
        args: {'key': 'notify_device', 'deviceRef': 'phone'},
      ));

      expect(reply, contains('paired device'));
      expect(store.currentPreference('notify_device'), isNull);
    });
  });

  group('KeywordBrain recognition', () {
    final brain = KeywordBrain();

    test('recognizes notify-device phrasings as a preference', () async {
      for (final phrase in [
        'only remind me on my phone',
        'always notify me on my phone',
        'notifications only on my laptop',
      ]) {
        final action = await brain.interpret(phrase);
        expect(action.command, NexusCommand.setPreference,
            reason: '"$phrase" should set a preference');
      }
    });

    test('extracts the device reference word', () async {
      final action = await brain.interpret('only remind me on my pc');
      expect(action.args['deviceRef'], 'pc');
    });

    test('does not mistake a real reminder for a preference', () async {
      final action = await brain.interpret('remind me to call Sam on my phone');
      expect(action.command, isNot(NexusCommand.setPreference));
      expect(action.command, NexusCommand.setReminder);
    });
  });
}
