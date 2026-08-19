import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/model_service.dart';
import '../ai/model_tiers.dart';
import '../settings/settings_service.dart';
import '../sync/knowledge_store.dart';

/// One file the maintenance pass wants to remove, with its size so the report
/// can say how much space was actually freed.
class StaleFile {
  final String path;
  final int sizeBytes;
  const StaleFile({required this.path, required this.sizeBytes});
}

/// What one maintenance run did. This is what gets logged and shown in
/// Settings — "visible, not silent", like every other part of Nexus.
class MaintenanceRunReport {
  final DateTime ranAt;
  final int filesRemoved;
  final int bytesFreed;
  final int knowledgeEventsPruned;
  final ModelIntegrityVerdict modelVerdict;
  final List<String> issues;

  const MaintenanceRunReport({
    required this.ranAt,
    required this.filesRemoved,
    required this.bytesFreed,
    required this.knowledgeEventsPruned,
    required this.modelVerdict,
    required this.issues,
  });

  bool get hasIssues => issues.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'ranAt': ranAt.toIso8601String(),
        'filesRemoved': filesRemoved,
        'bytesFreed': bytesFreed,
        'knowledgeEventsPruned': knowledgeEventsPruned,
        'modelVerdict': modelVerdict.name,
        'issues': issues,
      };

  factory MaintenanceRunReport.fromJson(Map<String, dynamic> json) =>
      MaintenanceRunReport(
        ranAt: DateTime.parse(json['ranAt'] as String),
        filesRemoved: json['filesRemoved'] as int? ?? 0,
        bytesFreed: json['bytesFreed'] as int? ?? 0,
        knowledgeEventsPruned: json['knowledgeEventsPruned'] as int? ?? 0,
        modelVerdict: ModelIntegrityVerdict.values.byName(
            json['modelVerdict'] as String? ?? 'none'),
        issues: [for (final i in json['issues'] as List? ?? const []) '$i'],
      );

  /// Short, honest label for the model self-check result.
  String get modelVerdictLabel => maintenanceModelVerdictLabel(modelVerdict);
}

/// Honest copy for each model self-check verdict. There is no \"dreaming\" and
/// no simulated testing — the check verifies the file is present, complete,
/// and loadable given current memory, nothing more.
String maintenanceModelVerdictLabel(ModelIntegrityVerdict v) {
  switch (v) {
    case ModelIntegrityVerdict.none:
      return 'no model installed';
    case ModelIntegrityVerdict.ok:
      return 'model verified';
    case ModelIntegrityVerdict.missing:
      return 'model file missing';
    case ModelIntegrityVerdict.incomplete:
      return 'model file incomplete';
    case ModelIntegrityVerdict.lowMemory:
      return 'model needs more free RAM';
  }
}

/// The \"sleep cycle\": real housekeeping the app does while the device is idle
/// so it stays fast and its data does not grow unbounded forever.
///
/// The four actions are all real and none is decorative:
///  1. Remove stale files — old dev-bridge prompt leftovers and build-artifact
///     tarballs, interrupted model/speech-model downloads, and temporary
///     copies of picked files — beyond a 7-day retention window.
///  2. Prune the append-only knowledge log via [KnowledgeStore.prune].
///  3. Lightweight model self-check via [ModelService.verifyIntegrity].
///  4. Persist and log the run (timestamp, what was cleaned, space freed, and
///     any issues) so it is visible in Settings.
class MaintenanceService {
  /// Shared by the app, the Settings screen, and the background task.
  static final MaintenanceService instance = MaintenanceService();

  static const _historyKey = 'nexus_maintenance_history';
  static const _historyLimit = 10;

  /// How old a file must be before maintenance removes it.
  static const staleFileRetention = Duration(days: 7);

  /// Linux/desktop: run at startup when the last run is older than this.
  static const opportunisticInterval = Duration(hours: 24);

  final KnowledgeStore _store;
  final ModelService _modelService;
  final Future<Directory> Function() _supportDirProvider;
  final Future<Directory> Function() _tempDirProvider;
  final Future<String?> Function() _devTaskCwdProvider;
  final DateTime Function() _now;

  MaintenanceService({
    KnowledgeStore? store,
    ModelService? modelService,
    Future<Directory> Function()? supportDirProvider,
    Future<Directory> Function()? tempDirProvider,
    Future<String?> Function()? devTaskCwdProvider,
    DateTime Function()? now,
  })  : _store = store ?? KnowledgeStore.instance,
        _modelService = modelService ?? ModelService(),
        _supportDirProvider = supportDirProvider ?? getApplicationSupportDirectory,
        _tempDirProvider = tempDirProvider ?? getTemporaryDirectory,
        _devTaskCwdProvider = devTaskCwdProvider ??
            (() async {
              final configured =
                  (await SettingsService().getDevTaskCwd()).trim();
              return configured.isEmpty ? null : configured;
            }),
        _now = now ?? DateTime.now;

  /// Runs one full maintenance pass and persists the report. Each action is
  /// best-effort: a failure is recorded as an issue, never thrown, so a single
  /// broken file can't stop the rest of the pass.
  Future<MaintenanceRunReport> run() async {
    final now = _now().toUtc();
    final issues = <String>[];
    var filesRemoved = 0;
    var bytesFreed = 0;
    var pruned = 0;

    // 1. Knowledge-log pruning (also records tombstones so re-synced events
    //    that were pruned here stay pruned — see KnowledgeStore.prune).
    try {
      await _store.init();
      pruned = await _store.prune(now: now);
    } catch (e) {
      issues.add('Knowledge-log pruning failed: $e');
    }

    // 2. Stale files.
    ModelIntegrityVerdict modelVerdict = ModelIntegrityVerdict.none;
    try {
      await _modelService.init();
      final supportDir = await _supportDirProvider();
      final tempDir = await _tempDirProvider();
      final cwd = await _devTaskCwdProvider();

      final stale = await findStaleFiles(
        now: now,
        retention: staleFileRetention,
        supportDir: supportDir,
        tempDir: tempDir,
        devTaskCwd: cwd,
        currentModelPath: _modelService.modelPath,
        modelDownloading: _modelService.isDownloading,
      );
      for (final f in stale) {
        try {
          await File(f.path).delete();
          filesRemoved++;
          bytesFreed += f.sizeBytes;
        } catch (e) {
          issues.add('Could not remove ${f.path}: $e');
        }
      }

      // 3. Model integrity self-check.
      modelVerdict = await _modelService.verifyIntegrity();
      switch (modelVerdict) {
        case ModelIntegrityVerdict.missing:
        case ModelIntegrityVerdict.incomplete:
          issues.add(
              'Local model check: ${maintenanceModelVerdictLabel(modelVerdict)} '
              '(re-download it from Settings > Local assistant).');
        case ModelIntegrityVerdict.lowMemory:
          issues.add(
              'Local model check: model needs more free RAM to load right '
              'now — it may fall back to command mode until memory frees up.');
        case ModelIntegrityVerdict.ok:
        case ModelIntegrityVerdict.none:
          break;
      }
    } catch (e) {
      issues.add('Stale-file cleanup / model check failed: $e');
    }

    final report = MaintenanceRunReport(
      ranAt: now,
      filesRemoved: filesRemoved,
      bytesFreed: bytesFreed,
      knowledgeEventsPruned: pruned,
      modelVerdict: modelVerdict,
      issues: issues,
    );
    await _persist(report);
    developer.log(
      'Maintenance run: removed $filesRemoved file(s) '
      '(${_humanBytes(bytesFreed)} freed), pruned $pruned knowledge event(s), '
      'model ${report.modelVerdictLabel}'
      '${issues.isEmpty ? '' : '; ${issues.length} issue(s): $issues'}',
      name: 'nexus.maintenance',
    );
    return report;
  }

  /// The most recent run, or null if maintenance has never run.
  Future<MaintenanceRunReport?> lastReport() async {
    final recent = await history();
    return recent.isEmpty ? null : recent.first;
  }

  /// Recent runs, newest first (bounded by [_historyLimit]).
  Future<List<MaintenanceRunReport>> history() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_historyKey) ?? const [];
    return [
      for (final r in raw)
        MaintenanceRunReport.fromJson(jsonDecode(r) as Map<String, dynamic>),
    ];
  }

  /// True when maintenance has never run, or the last run is older than
  /// [interval]. Used by the Linux/desktop startup path (Android uses a
  /// periodic WorkManager task instead).
  Future<bool> isDue({Duration interval = opportunisticInterval}) async {
    final last = await lastReport();
    if (last == null) return true;
    return _now().isAfter(last.ranAt.add(interval));
  }

  /// Runs maintenance now if it is due; returns the new report, or null when
  /// nothing needed to run. This is the honest Linux/desktop behaviour: an
  /// opportunistic check at startup, not a background service while closed.
  Future<MaintenanceRunReport?> runIfDue({
    Duration interval = opportunisticInterval,
  }) async {
    return await isDue(interval: interval) ? run() : null;
  }

  Future<void> _persist(MaintenanceRunReport report) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await history();
    final updated = [report, ...existing.where((e) => e.ranAt != report.ranAt)];
    if (updated.length > _historyLimit) {
      updated.removeRange(_historyLimit, updated.length);
    }
    await prefs.setStringList(
      _historyKey,
      [for (final r in updated) jsonEncode(r.toJson())],
    );
  }

  // ---- stale-file discovery (pure w.r.t. the directories passed in) ------

  /// Lists files that should be removed, without removing anything. The list
  /// is deliberately narrow — only files Nexus itself creates — so a test (or
  /// a cautious reader) can see it never touches anything the user might still
  /// need.
  ///
  /// Targets:
  ///  * `<support>/devbridge/` — prompt/log leftovers from dev-bridge tasks.
  ///  * `<cwd>/build/devbridge/nexus-linux-bundle-*.tar.gz` — Linux bundle
  ///    tarballs the dev bridge packs for the phone.
  ///  * `<support>/models/*.gguf` — partial files from an interrupted model
  ///    download (anything smaller than its tier's expected size, or an
  ///    unknown name). The currently-installed model is never touched.
  ///  * `<support>/vosk/model.zip` — leftover from an interrupted speech-model
  ///    download (deleted on success).
  ///  * `<temp>/nexus_send_tmp/` — temporary copies of picked files.
  static Future<List<StaleFile>> findStaleFiles({
    required DateTime now,
    required Duration retention,
    required Directory supportDir,
    required Directory tempDir,
    required String? devTaskCwd,
    required String? currentModelPath,
    required bool modelDownloading,
  }) async {
    final stale = <StaleFile>[];
    final cutoff = now.subtract(retention);

    Future<void> collect(File f) async {
      try {
        final modified = await f.lastModified();
        if (modified.isAfter(cutoff)) return;
        stale.add(StaleFile(path: f.path, sizeBytes: await f.length()));
      } catch (_) {
        // Vanished or unreadable mid-scan — skip.
      }
    }

    final devBridgeDir = Directory(p.join(supportDir.path, 'devbridge'));
    if (await devBridgeDir.exists()) {
      await for (final e in devBridgeDir.list()) {
        if (e is File) await collect(e);
      }
    }

    if (devTaskCwd != null && devTaskCwd.isNotEmpty) {
      final artifactsDir = Directory(p.join(devTaskCwd, 'build', 'devbridge'));
      if (await artifactsDir.exists()) {
        await for (final e in artifactsDir.list()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.startsWith('nexus-linux-bundle-') ||
              !name.endsWith('.tar.gz')) {
            continue;
          }
          await collect(e);
        }
      }
    }

    if (!modelDownloading) {
      final modelsDir = Directory(p.join(supportDir.path, 'models'));
      if (await modelsDir.exists()) {
        await for (final e in modelsDir.list()) {
          if (e is! File || !e.path.endsWith('.gguf')) continue;
          if (currentModelPath != null && e.path == currentModelPath) continue;
          final name = p.basenameWithoutExtension(e.path);
          ModelTier? tier;
          for (final t in ModelTier.all) {
            if (t.id == name) {
              tier = t;
              break;
            }
          }
          if (tier != null && await e.length() >= tier.sizeBytes) {
            continue; // a complete download; leave it (may be an older tier)
          }
          await collect(e);
        }
      }
      final voskZip = File(p.join(supportDir.path, 'vosk', 'model.zip'));
      if (await voskZip.exists()) await collect(voskZip);
    }

    final sendTmpDir = Directory(p.join(tempDir.path, 'nexus_send_tmp'));
    if (await sendTmpDir.exists()) {
      await for (final e in sendTmpDir.list()) {
        if (e is File) await collect(e);
      }
    }

    return stale;
  }

  static String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
