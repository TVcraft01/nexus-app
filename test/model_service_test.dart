import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/model_service.dart';
import 'package:nexus_app/ai/model_tiers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelService', () {
    test('deleteModel() removes the file and reverts to command mode', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_model_test');
      addTearDown(() => dir.delete(recursive: true));
      final modelFile = File(p.join(dir.path, 'compact.gguf'));
      await modelFile.writeAsString('fake model bytes');

      SharedPreferences.setMockInitialValues({
        'ai_model_state': 'ready',
        'ai_model_tier': 'compact',
        'ai_model_path': modelFile.path,
        'ai_model_size': 986048768,
        'ai_model_declined': false,
      });

      final service = ModelService();
      await service.init();
      expect(service.isReady, isTrue);
      expect(service.tier?.id, 'compact');
      expect(service.modelPath, modelFile.path);

      await service.deleteModel();

      expect(service.isReady, isFalse);
      expect(service.state, ModelState.none);
      expect(service.tier, isNull);
      expect(service.modelPath, isNull);
      expect(modelFile.existsSync(), isFalse,
          reason: 'the model file should actually be deleted');

      // Persistence: a fresh service reading the same prefs sees the revert.
      final service2 = ModelService();
      await service2.init();
      expect(service2.isReady, isFalse);
      expect(service2.tier, isNull);
      expect(service2.declined, isFalse);
    });

    test('declined flag persists across init()', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ModelService();
      await service.init();
      expect(service.declined, isFalse);

      await service.setDeclined(true);
      expect(service.declined, isTrue);

      final service2 = ModelService();
      await service2.init();
      expect(service2.declined, isTrue);
    });

    test('snoozePrompt() defers the prompt and persists across init()',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = ModelService();
      await service.init();
      expect(service.isSnoozed, isFalse,
          reason: 'no snooze before the user taps Not now');

      await service.snoozePrompt();
      expect(service.isSnoozed, isTrue,
          reason: 'the prompt should be quiet for the snooze window');

      // A fresh service reading the same prefs also sees the snooze.
      final service2 = ModelService();
      await service2.init();
      expect(service2.isSnoozed, isTrue);
    });

    test('an expired snooze no longer blocks the prompt', () async {
      final expired =
          DateTime.now().subtract(const Duration(days: 10)).toIso8601String();
      SharedPreferences.setMockInitialValues({'ai_model_snoozed_until': expired});
      final service = ModelService();
      await service.init();
      expect(service.isSnoozed, isFalse,
          reason: 'a stale snooze timestamp must not suppress the prompt');
    });

    test('clearSnooze() forgets a pending snooze', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ModelService();
      await service.init();
      await service.snoozePrompt();
      expect(service.isSnoozed, isTrue);

      await service.clearSnooze();
      expect(service.isSnoozed, isFalse);

      final service2 = ModelService();
      await service2.init();
      expect(service2.isSnoozed, isFalse,
          reason: 'the cleared snooze must not come back after init()');
    });

    test('re-enabling from Settings cancels an active snooze', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ModelService();
      await service.init();
      await service.snoozePrompt();
      expect(service.isSnoozed, isTrue);

      await service.setDeclined(false); // the Settings "Enable" path
      expect(service.isSnoozed, isFalse);
    });
  });

  group('pickTierFor', () {
    const gb = 1024 * 1024 * 1024;
    DeviceCapability cap({required int freeRam, required int freeDisk}) =>
        DeviceCapability(
          freeRamBytes: freeRam,
          cpuCores: 8,
          freeDiskBytes: freeDisk,
        );

    test('returns null when free RAM is below even the Tiny threshold', () {
      expect(
        pickTierFor(cap(freeRam: 512 * 1024 * 1024, freeDisk: 100 * gb)),
        isNull,
      );
    });

    test('offers Tiny on a low-RAM small ARM device', () {
      // 2 GB free RAM: fits Tiny (768 MB) but not Compact (3 GB).
      expect(pickTierFor(cap(freeRam: 2 * gb, freeDisk: 100 * gb))?.id, 'tiny');
    });

    test('offers Compact when only Compact-and-below fit', () {
      // 3.5 GB free RAM: fits Compact (3 GB) but not Balanced (4 GB).
      expect(pickTierFor(cap(freeRam: 7 * gb ~/ 2, freeDisk: 100 * gb))?.id,
          'compact');
    });

    test('offers Balanced on a mid-range device', () {
      // 5 GB free RAM: fits Balanced (4 GB) but not Large (7 GB).
      expect(pickTierFor(cap(freeRam: 5 * gb, freeDisk: 100 * gb))?.id,
          'balanced');
    });

    test('offers Large on a high-RAM device', () {
      expect(pickTierFor(cap(freeRam: 32 * gb, freeDisk: 100 * gb))?.id,
          'large');
    });

    test('falls back to Balanced when RAM fits Large but disk does not', () {
      // Large needs ~7 GB free disk (4.4 GB * 1.5); 5 GB is not enough, so
      // the largest tier that satisfies every requirement is Balanced.
      expect(pickTierFor(cap(freeRam: 32 * gb, freeDisk: 5 * gb))?.id,
          'balanced');
    });
  });
}
