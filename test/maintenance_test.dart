import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/model_service.dart';
import 'package:nexus_app/ai/model_tiers.dart';
import 'package:nexus_app/maintenance/maintenance_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('MaintenanceService.findStaleFiles', () {
    test('removes only old Nexus-created files, never fresh or foreign ones',
        () async {
      final root = await Directory.systemTemp.createTemp('nexus_maint_test');
      addTearDown(() => root.delete(recursive: true));
      final support = Directory(p.join(root.path, 'support'))
        ..createSync(recursive: true);
      final temp = Directory(p.join(root.path, 'temp'))
        ..createSync(recursive: true);
      final cwd = Directory(p.join(root.path, 'repo'))
        ..createSync(recursive: true);

      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 30));

      Future<File> write(String path, String content, DateTime mtime) async {
        final f = File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync(content);
        await f.setLastModified(mtime);
        return f;
      }

      // Stale dev-bridge prompt leftover vs. a fresh in-flight file.
      final oldPrompt = await write(
          p.join(support.path, 'devbridge', 'prompt.txt'), 'prompt', old);
      final freshPrompt = await write(
          p.join(support.path, 'devbridge', 'fresh.txt'), 'x', now);

      // Old Nexus artifact tarball vs. a foreign file that must never be
      // touched (it is not something Nexus created).
      final oldTar = await write(
          p.join(cwd.path, 'build', 'devbridge', 'nexus-linux-bundle-1.tar.gz'),
          'tar',
          old);
      final foreign = await write(
          p.join(cwd.path, 'build', 'devbridge', 'user-notes.tar.gz'),
          'keep',
          old);

      // Interrupted model download (compact.gguf too small) vs. the installed
      // complete model.
      final partialModel = await write(
          p.join(support.path, 'models', 'compact.gguf'), 'partial', old);
      final completeModel = await write(
          p.join(support.path, 'models', 'balanced.gguf'), 'complete', now);

      // Interrupted Vosk speech-model download.
      final voskZip = await write(
          p.join(support.path, 'vosk', 'model.zip'), 'zip', old);

      // Temporary send copies: old removed, fresh kept.
      final oldSend = await write(
          p.join(temp.path, 'nexus_send_tmp', 'a.txt'), 'a', old);
      final freshSend = await write(
          p.join(temp.path, 'nexus_send_tmp', 'b.txt'), 'b', now);

      final stale = await MaintenanceService.findStaleFiles(
        now: now,
        retention: const Duration(days: 7),
        supportDir: support,
        tempDir: temp,
        devTaskCwd: cwd.path,
        currentModelPath: completeModel.path,
        modelDownloading: false,
      );

      final paths = stale.map((f) => f.path).toSet();
      expect(paths, containsAll([
        oldPrompt.path,
        oldTar.path,
        partialModel.path,
        voskZip.path,
        oldSend.path,
      ]));
      expect(paths, isNot(contains(freshPrompt.path)));
      expect(paths, isNot(contains(foreign.path)),
          reason: 'never delete a file Nexus did not create');
      expect(paths, isNot(contains(completeModel.path)),
          reason: 'never delete the installed model');
      expect(paths, isNot(contains(freshSend.path)));
    });

    test('does not touch the models dir while a download is in progress',
        () async {
      final root = await Directory.systemTemp.createTemp('nexus_maint_test');
      addTearDown(() => root.delete(recursive: true));
      final support = Directory(p.join(root.path, 'support'))
        ..createSync(recursive: true);
      final temp = Directory(p.join(root.path, 'temp'))
        ..createSync(recursive: true);

      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 30));

      final partial = File(p.join(support.path, 'models', 'compact.gguf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('partial');
      await partial.setLastModified(old);

      final stale = await MaintenanceService.findStaleFiles(
        now: now,
        retention: const Duration(days: 7),
        supportDir: support,
        tempDir: temp,
        devTaskCwd: null,
        currentModelPath: null,
        modelDownloading: true,
      );

      expect(stale.map((f) => f.path), isNot(contains(partial.path)));
    });
  });

  group('model integrity self-check', () {
    test('verdict none when no model is installed', () async {
      final service = ModelService();
      await service.init();
      expect(await service.verifyIntegrity(), ModelIntegrityVerdict.none);
    });

    test('verdict missing when the persisted file is gone', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_maint_model');
      addTearDown(() => dir.delete(recursive: true));
      final missingPath = p.join(dir.path, 'compact.gguf');

      SharedPreferences.setMockInitialValues({
        'ai_model_state': 'ready',
        'ai_model_tier': 'compact',
        'ai_model_path': missingPath,
        'ai_model_size': 986048768,
      });
      final service = ModelService();
      await service.init();
      expect(await service.verifyIntegrity(), ModelIntegrityVerdict.missing);
    });

    test('verdict incomplete for a truncated model file', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_maint_model');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'compact.gguf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('only a few bytes');

      SharedPreferences.setMockInitialValues({
        'ai_model_state': 'ready',
        'ai_model_tier': 'compact',
        'ai_model_path': file.path,
        'ai_model_size': 986048768,
      });
      final service = ModelService();
      await service.init();
      expect(await service.verifyIntegrity(), ModelIntegrityVerdict.incomplete,
          reason: 'a partially-failed download must be caught early');
    });

    test('verdict ok for a complete model the device can load', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_maint_model');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'compact.gguf'));
      // Sparse file: correct logical size without writing a real ~941 MB.
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(ModelTier.compact.sizeBytes);
      await raf.close();

      SharedPreferences.setMockInitialValues({
        'ai_model_state': 'ready',
        'ai_model_tier': 'compact',
        'ai_model_path': file.path,
        'ai_model_size': ModelTier.compact.sizeBytes,
      });
      final service = ModelService();
      await service.init();
      expect(
        await service.verifyIntegrity(
          freeRamBytesOverride: ModelTier.compact.minFreeRamBytes,
        ),
        ModelIntegrityVerdict.ok,
      );
    });

    test('verdict lowMemory when the device can no longer load the tier',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus_maint_model');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'compact.gguf'));
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(ModelTier.compact.sizeBytes);
      await raf.close();

      SharedPreferences.setMockInitialValues({
        'ai_model_state': 'ready',
        'ai_model_tier': 'compact',
        'ai_model_path': file.path,
        'ai_model_size': ModelTier.compact.sizeBytes,
      });
      final service = ModelService();
      await service.init();
      expect(
        await service.verifyIntegrity(
          freeRamBytesOverride: ModelTier.compact.minFreeRamBytes - 1,
        ),
        ModelIntegrityVerdict.lowMemory,
      );
    });
  });
}
