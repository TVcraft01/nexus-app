/// PC-side dev-bridge: receives a dev-task prompt from a paired device over
/// the encrypted channel, runs a configurable command (a wrapper around the
/// user's coding agent), captures its output, and sends the report — plus any
/// build artifact — back over the existing encrypted transfer path.
///
/// Safety model:
///  * The endpoint only answers requests authenticated by a pairing key
///    (TransferService checks that before delegating here).
///  * "Allow remote dev tasks" must be ON (default OFF, separate from the
///    internet toggle) or the request is rejected with a clear message.
///  * One dev task at a time; a second request while one is running gets a
///    clear rejection instead of queueing.
///  * The prompt is passed to a user-configured command, never executed
///    directly, so exactly what runs is visible and editable in Settings.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';

import '../models/paired_device.dart';
import '../settings/settings_service.dart';
import '../tasks/task_crypto.dart';
import 'dev_bridge_protocol.dart';

/// A build artifact produced by a dev task, ready to send back to the phone.
class DevTaskArtifact {
  final String path;
  final String fileName;
  const DevTaskArtifact({required this.path, required this.fileName});
}

/// What a dev-task run produced. [report] is the full user-facing text;
/// [artifact] is the build output to push back, if any.
class DevTaskOutcome {
  final String report;
  final DevTaskArtifact? artifact;
  const DevTaskOutcome({required this.report, this.artifact});
}

/// How the actual task is executed. Tests inject a fake; the default runs the
/// user-configured shell command.
typedef DevTaskRunner =
    Future<DevTaskOutcome> Function(String prompt, {required String cwd});

/// Pushes a produced artifact back to the requesting phone over the existing
/// encrypted file-transfer path.
typedef DevArtifactPusher = Future<void> Function(
    PairedDevice target, String filePath);

class DevBridgeService {
  static final DevBridgeService instance = DevBridgeService._();

  DevBridgeService._();

  final SettingsService _settings = SettingsService();

  /// How long a dev task may run before it is killed. These are real agentic
  /// / build tasks (a Flutter APK build alone can take 10-15 minutes), so the
  /// default is generous.
  static const taskTimeout = Duration(minutes: 30);

  DevTaskRunner? _runner;
  DevArtifactPusher? _pusher;
  bool _busy = false;

  /// True while a dev task is executing. Read by the Settings screen.
  bool get busy => _busy;

  /// Injects the runner and artifact pusher. The app wires the pusher to the
  /// real TransferService.sendFile; tests inject fakes for both.
  void init({DevTaskRunner? runner, DevArtifactPusher? pusher}) {
    if (runner != null) _runner = runner;
    if (pusher != null) _pusher = pusher;
  }

  /// Resets singleton state so tests start from a clean slate.
  @visibleForTesting
  void debugReset() {
    _busy = false;
    _runner = null;
    _pusher = null;
  }

  /// Handles an incoming POST /devtask from [device] (already authenticated by
  /// the pairing key at the TransferService layer).
  Future<Response> handleDevTask(Request request, PairedDevice device) async {
    if (!await _settings.getAllowDevTasks()) {
      return devTaskRejection(
        'Remote dev tasks are disabled on this device. Turn on '
        '"Allow remote dev tasks" in Settings > Developer bridge.',
        status: 403,
      );
    }

    final keyBytes = base64Decode(device.transferKey);
    final List<int> encrypted;
    try {
      encrypted = await request.read().expand((chunk) => chunk).toList();
    } catch (e) {
      return devTaskRejection('Could not read the request: $e', status: 400);
    }

    final String prompt;
    try {
      final plain = await decryptTaskPayload(encrypted, keyBytes);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      prompt = (json['prompt'] as String? ?? '').trim();
    } catch (e) {
      return devTaskRejection(
          'Could not decrypt the task request (bad pairing key or '
          'tampered payload): $e',
          status: 400);
    }

    if (prompt.isEmpty) {
      return devTaskRejection('The task prompt is empty.', status: 400);
    }

    if (_busy) {
      return devTaskRejection(
        'A dev task is already running on this device. Only one task at a '
        'time — wait for it to finish, then try again.',
        status: 409,
      );
    }

    _busy = true;
    try {
      final outcome = await _runTask(prompt);
      var report = outcome.report;

      DevTaskArtifact? sent;
      if (outcome.artifact != null) {
        final pusher = _pusher;
        if (pusher == null) {
          report +=
              '\n\nArtifact was produced (${outcome.artifact!.fileName}) but '
              'the app is not wired to send files back on this device.';
        } else {
          try {
            await pusher(device, outcome.artifact!.path);
            sent = outcome.artifact;
            report +=
                '\n\nArtifact sent back: ${outcome.artifact!.fileName} '
                '(transferred over the encrypted file path).';
          } catch (e) {
            report +=
                '\n\nArtifact ${outcome.artifact!.fileName} was produced but '
                'could not be sent back: $e';
          }
        }
      }

      return Response.ok(
        await devTaskResponseBody(
          keyBytes,
          statusOk: true,
          report: report,
          artifactFileName: sent?.fileName,
          artifactPath: sent?.path,
        ),
        headers: {'content-type': 'application/octet-stream'},
      );
    } catch (e) {
      return Response.ok(
        await devTaskResponseBody(
          keyBytes,
          statusOk: false,
          report: '',
          error: 'The dev task failed on this device: $e',
        ),
        headers: {'content-type': 'application/octet-stream'},
      );
    } finally {
      _busy = false;
    }
  }

  Future<DevTaskOutcome> _runTask(String prompt) async {
    final runner = _runner;
    if (runner == null) {
      return DevTaskOutcome(
        report: 'No task runner is configured on this device.',
      );
    }
    final cwd = await _resolveCwd();
    return runner(prompt, cwd: cwd);
  }

  Future<String> _resolveCwd() async {
    final configured = (await _settings.getDevTaskCwd()).trim();
    if (configured.isNotEmpty && await Directory(configured).exists()) {
      return configured;
    }
    return Directory.current.path;
  }

  // ---- default runner (user-configured shell command) --------------------

  /// Runs the configured command with {prompt} / {promptFile} substituted,
  /// captures stdout+stderr, and discovers any build artifact afterwards.
  ///
  /// This is the default [DevTaskRunner]. The command is a template the user
  /// edits in Settings; the prompt is never concatenated into a shell line
  /// without going through it (use {promptFile} to avoid quoting issues).
  Future<DevTaskOutcome> runConfiguredCommand(
    String prompt, {
    required String cwd,
  }) async {
    final command = await _settings.getDevTaskCommand();
    final promptFile = await _writePromptFile(prompt);
    final expanded = expandTaskCommand(command, prompt, promptFile);
    final shell = Platform.isWindows ? 'cmd' : '/bin/sh';
    final shellArgs =
        Platform.isWindows ? <String>['/c', expanded] : <String>['-c', expanded];

    final started = DateTime.now();
    final process =
        await Process.start(shell, shellArgs, workingDirectory: cwd);
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(stdout.write);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    // Give the pipe a beat to deliver any output the child wrote before the
    // listeners above were fully active. Some constrained environments drop
    // early stdout otherwise; a sub-100ms settle is noise next to tasks that
    // run for minutes, and harmless on normal machines.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    var timedOut = false;
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(taskTimeout);
    } on TimeoutException {
      timedOut = true;
      process.kill();
      exitCode = await process.exitCode
          .timeout(const Duration(seconds: 10))
          .catchError((_) => -1);
    }

    final elapsed = DateTime.now().difference(started);
    final b = StringBuffer()
      ..writeln('Dev task finished (exit code $exitCode, '
          '${elapsed.inSeconds}s).')
      ..writeln()
      ..writeln('Prompt sent to the task: $prompt')
      ..writeln()
      ..writeln('--- task output ---');
    final out = stdout.toString().trim();
    final err = stderr.toString().trim();
    if (out.isNotEmpty) b.writeln(out);
    if (err.isNotEmpty) {
      b.writeln();
      b.writeln('--- stderr ---');
      b.writeln(err);
    }
    if (timedOut) {
      b.writeln();
      b.writeln('The task was stopped after ${taskTimeout.inMinutes} minutes '
          'without finishing.');
    }

    final artifact = await discoverArtifact(cwd);
    return DevTaskOutcome(report: b.toString().trim(), artifact: artifact);
  }

  /// Writes the prompt to a file so a task command can read it safely (no
  /// shell-quoting issues, no prompt-length limits). Returns the file path.
  /// Falls back to the system temp dir when the platform support directory
  /// isn't available (e.g. in a bare unit test).
  Future<String> _writePromptFile(String prompt) async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final folder = Directory(p.join(base.path, 'devbridge'));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, 'prompt.txt'));
    await file.writeAsString(prompt);
    return file.path;
  }

  // ---- pure helpers (unit-testable) --------------------------------------

  /// Substitutes {prompt} and {promptFile} into a task command template.
  /// {promptFile} is replaced first so it can't be corrupted by a {prompt}
  /// match inside it.
  static String expandTaskCommand(
    String command,
    String prompt,
    String promptFile,
  ) {
    var out = command.replaceAll('{promptFile}', promptFile);
    out = out.replaceAll('{prompt}', prompt);
    return out;
  }

  /// Finds the newest build artifact under [cwd]: any debug/release APK under
  /// build/app, or the Linux release bundle (tar.gz'd into
  /// build/devbridge/ so it can ride the single-file transfer path). Returns
  /// null when no build output exists.
  static Future<DevTaskArtifact?> discoverArtifact(String cwd) async {
    final candidates = <File>[];

    for (final rel in const [
      'build/app/outputs/flutter-apk',
      'build/app/outputs/apk',
    ]) {
      final dir = Directory(p.join(cwd, rel));
      if (!await dir.exists()) continue;
      await for (final e in dir.list(recursive: true)) {
        if (e is File && e.path.endsWith('.apk')) candidates.add(e);
      }
    }

    // Linux desktop bundle: a directory, so pack it into a tarball first.
    final linuxBuild = Directory(p.join(cwd, 'build', 'linux'));
    if (await linuxBuild.exists()) {
      final bundles = <Directory>[];
      await for (final e in linuxBuild.list(recursive: true)) {
        if (e is Directory &&
            p.basename(e.path) == 'bundle' &&
            p.basename(p.dirname(e.path)) == 'release') {
          bundles.add(e);
        }
      }
      if (bundles.isNotEmpty) {
        final bundle = bundles.first;
        final outDir = Directory(p.join(cwd, 'build', 'devbridge'));
        await outDir.create(recursive: true);
        final tar = File(p.join(outDir.path,
            'nexus-linux-bundle-${DateTime.now().millisecondsSinceEpoch}.tar.gz'));
        try {
          final res = await Process.run('tar', [
            '-czf', tar.path,
            '-C', bundle.parent.path,
            p.basename(bundle.path),
          ]);
          if (res.exitCode == 0 && await tar.exists()) candidates.add(tar);
        } catch (_) {
          // tar unavailable — skip the bundle, APKs may still exist.
        }
      }
    }

    File? newest;
    for (final f in candidates) {
      if (newest == null ||
          (await f.lastModified()).isAfter(await newest.lastModified())) {
        newest = f;
      }
    }
    if (newest == null) return null;
    return DevTaskArtifact(path: newest.path, fileName: p.basename(newest.path));
  }
}
