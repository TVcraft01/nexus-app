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
    DeviceCapability cap({required int freeRam, required int freeDisk}) =>
        DeviceCapability(
          freeRamBytes: freeRam,
          cpuCores: 8,
          freeDiskBytes: freeDisk,
        );

    test('returns null when free RAM is below the compact threshold', () {
      expect(
        pickTierFor(cap(
          freeRam: 2 * 1024 * 1024 * 1024,
          freeDisk: 100 * 1024 * 1024 * 1024,
        )),
        isNull,
      );
    });

    test('returns compact with sufficient RAM and disk', () {
      expect(
        pickTierFor(cap(
          freeRam: 4 * 1024 * 1024 * 1024,
          freeDisk: 100 * 1024 * 1024 * 1024,
        ))?.id,
        'compact',
      );
    });

    test('returns compact on a high-RAM device (smallest-first, documented)', () {
      // pickTierFor currently returns the *smallest* tier that fits, not the
      // largest. The adaptive-model spec implied "largest that fits", so this
      // may be inverted; left unchanged here to keep this change focused on
      // the three test-pass bugs. See the pickTierFor doc comment.
      expect(
        pickTierFor(cap(
          freeRam: 8 * 1024 * 1024 * 1024,
          freeDisk: 10 * 1024 * 1024 * 1024,
        ))?.id,
        'compact',
      );
    });
  });
}
