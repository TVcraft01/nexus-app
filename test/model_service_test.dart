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
  });

  group('pickTierFor', () {
    const gb = 1024 * 1024 * 1024;
    DeviceCapability cap({required int freeRam, required int freeDisk}) =>
        DeviceCapability(
          freeRamBytes: freeRam,
          cpuCores: 8,
          freeDiskBytes: freeDisk,
        );

    test('returns null when free RAM is below the compact threshold', () {
      expect(pickTierFor(cap(freeRam: 2 * gb, freeDisk: 100 * gb)), isNull);
    });

    test('offers Compact when only the smallest tier fits', () {
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
