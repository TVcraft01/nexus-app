import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/devbridge/dev_bridge_protocol.dart';
import 'package:nexus_app/devbridge/dev_bridge_service.dart';
import 'package:nexus_app/models/paired_device.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

void main() {
  // NOTE: no TestWidgetsFlutterBinding here — it replaces HttpClient with a
  // mock, which would break the real shelf server used to exercise the
  // encrypted exchange (same pattern as sync_test.dart).

  setUp(() {
    DevBridgeService.instance.debugReset();
  });

  PairedDevice device({String key = 'test-pair-key'}) => PairedDevice(
        deviceId: 'pc-1',
        deviceName: 'PC',
        ipAddress: '127.0.0.1',
        port: 0,
        pairingKey: key,
      );

  Future<HttpServer> serve(DevBridgeService service, PairedDevice d) async {
    final handler = const Pipeline()
        .addHandler((request) => service.handleDevTask(request, d));
    final server =
        await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    return server;
  }

  group('safety gating', () {
    test('a request is rejected when the toggle is off', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': false,
      });
      final ran = <String>[];
      final service = DevBridgeService.instance;
      service.init(runner: (prompt, {required cwd}) async {
        ran.add(prompt);
        return const DevTaskOutcome(report: 'should not run');
      });

      final d = device();
      final server = await serve(service, d);
      final result =
          await sendDevTask(device: d, prompt: 'build the apk', port: server.port);

      expect(ran, isEmpty, reason: 'the toggle is off, nothing may run');
      expect(result.ok, isFalse);
      expect(result.error, contains('disabled'));
      expect(result.error, contains('Allow remote dev tasks'));
    });

    test('an empty prompt is rejected even when the toggle is on', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': true,
      });
      final service = DevBridgeService.instance;
      final d = device();
      final server = await serve(service, d);

      final result = await sendDevTask(device: d, prompt: '   ', port: server.port);
      expect(result.ok, isFalse);
      expect(result.error, contains('empty'));
    });
  });

  group('encrypted round-trip', () {
    test('a prompt runs on the peer and the report comes back decrypted',
        () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': true,
      });

      final ran = <String>[];
      final pushed = <(PairedDevice, String)>[];
      final service = DevBridgeService.instance;
      service.init(
        runner: (prompt, {required cwd}) async {
          ran.add(prompt);
          return const DevTaskOutcome(
            report: 'Fixed the failing test. flutter analyze is clean.',
            artifact: DevTaskArtifact(
              path: '/tmp/build/app-debug.apk',
              fileName: 'app-debug.apk',
            ),
          );
        },
        pusher: (target, path) async => pushed.add((target, path)),
      );

      final d = device();
      final server = await serve(service, d);
      final result = await sendDevTask(
        device: d,
        prompt: 'Fix the failing test in nexus_action_runner.dart',
        port: server.port,
      );

      expect(ran, ['Fix the failing test in nexus_action_runner.dart']);
      expect(result.ok, isTrue);
      expect(result.report, contains('Fixed the failing test'));
      expect(result.artifactFileName, 'app-debug.apk');
      expect(result.artifactPath, '/tmp/build/app-debug.apk');
      // The artifact was pushed back over the encrypted transfer path.
      expect(pushed, hasLength(1));
      expect(pushed.single.$1.deviceId, d.deviceId);
      expect(pushed.single.$2, '/tmp/build/app-debug.apk');
    });

    test('an artifact push failure is reported, not a hard failure', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': true,
      });
      final service = DevBridgeService.instance;
      service.init(
        runner: (prompt, {required cwd}) async => const DevTaskOutcome(
          report: 'built ok',
          artifact: DevTaskArtifact(
              path: '/tmp/build/app-debug.apk', fileName: 'app-debug.apk'),
        ),
        pusher: (target, path) async => throw Exception('phone unreachable'),
      );

      final d = device();
      final server = await serve(service, d);
      final result =
          await sendDevTask(device: d, prompt: 'build', port: server.port);

      expect(result.ok, isTrue);
      expect(result.report, contains('could not be sent back'));
      expect(result.report, contains('phone unreachable'));
      expect(result.artifactFileName, isNull,
          reason: 'only a successfully sent artifact is advertised');
    });

    test('a wrong pairing key cannot decrypt or act', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': true,
      });
      final service = DevBridgeService.instance;
      service.init(runner: (prompt, {required cwd}) async {
        fail('the runner must never fire for an unauthenticated peer');
      });

      // Server authenticates with key A, client sends with key B.
      final serverDevice = device(key: 'key-A');
      final server = await serve(service, serverDevice);
      final impostor = device(key: 'key-B');

      final result =
          await sendDevTask(device: impostor, prompt: 'run me', port: server.port);
      expect(result.ok, isFalse);
      expect(result.error, contains('decrypt'));
    });
  });

  group('one dev task at a time', () {
    test('a second request is rejected while one is running', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': true,
      });
      final gate = Completer<void>();
      final service = DevBridgeService.instance;
      service.init(runner: (prompt, {required cwd}) async {
        await gate.future;
        return const DevTaskOutcome(report: 'done');
      });

      final d = device();
      final server = await serve(service, d);

      final first =
          sendDevTask(device: d, prompt: 'slow task', port: server.port);
      // Give the first request time to reach the runner.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final second =
          await sendDevTask(device: d, prompt: 'another', port: server.port);
      expect(second.ok, isFalse);
      expect(second.error, contains('already running'));
      expect(second.error, contains('one task at a time'));

      gate.complete();
      final firstResult = await first;
      expect(firstResult.ok, isTrue);
      expect(firstResult.report, 'done');
    });
  });

  group('command template', () {
    test('{prompt} and {promptFile} are substituted, {promptFile} intact', () {
      final out = DevBridgeService.expandTaskCommand(
        'bash /home/me/devtask.sh "{prompt}" --input "{promptFile}"',
        'fix the "quote" bug',
        '/tmp/prompt.txt',
      );
      expect(out, contains('bash /home/me/devtask.sh "fix the "quote" bug"'));
      expect(out, contains('--input "/tmp/prompt.txt"'));
    });

    test('{promptFile} is not corrupted by an earlier {prompt} match', () {
      final out = DevBridgeService.expandTaskCommand(
        'cat {promptFile}',
        'anything',
        '/p/promptFile.txt',
      );
      expect(out, 'cat /p/promptFile.txt',
          reason: 'the {prompt} match inside {promptFile} must not apply');
    });
  });

  group('artifact discovery', () {
    test('picks the newest APK under build/app', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_devtest');
      addTearDown(() => dir.delete(recursive: true));

      final oldApk = File('${dir.path}/build/app/outputs/flutter-apk/app-release.apk')
        ..createSync(recursive: true)
        ..writeAsStringSync('release');
      final newApk = File('${dir.path}/build/app/outputs/flutter-apk/app-debug.apk')
        ..writeAsStringSync('debug');
      // Make sure the debug APK is clearly newer.
      final oldTime = DateTime.now().subtract(const Duration(hours: 1));
      await oldApk.setLastModified(oldTime);
      await newApk.setLastModified(DateTime.now());

      final artifact = await DevBridgeService.discoverArtifact(dir.path);
      expect(artifact, isNotNull);
      expect(artifact!.fileName, 'app-debug.apk');
    });

    test('packs the Linux release bundle into a tarball', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_devtest');
      addTearDown(() => dir.delete(recursive: true));

      File('${dir.path}/build/linux/x64/release/bundle/nexus')
        ..createSync(recursive: true)
        ..writeAsStringSync('binary');

      final artifact = await DevBridgeService.discoverArtifact(dir.path);
      expect(artifact, isNotNull);
      expect(artifact!.fileName, endsWith('.tar.gz'));
      expect(await File(artifact.path).exists(), isTrue);
    });

    test('returns null when nothing was built', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_devtest');
      addTearDown(() => dir.delete(recursive: true));
      final artifact = await DevBridgeService.discoverArtifact(dir.path);
      expect(artifact, isNull);
    });
  });

  group('default runner', () {
    test('runs the configured command and captures output', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': true,
        'nexus_dev_task_command': 'echo "got: {prompt}"',
      });
      final service = DevBridgeService.instance;
      final outcome = await service.runConfiguredCommand(
        'hello from the phone',
        cwd: Directory.systemTemp.createTempSync('nexus_devtest').path,
      );
      expect(outcome.report, contains('got: hello from the phone'));
      expect(outcome.report, contains('exit code 0'));
    });
  });

  group('rejections read cleanly on the client', () {
    test('toggle-off 403 surfaces the message instead of raw JSON', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_allow_dev_tasks': false,
      });
      final service = DevBridgeService.instance;
      final d = device();
      final server = await serve(service, d);

      final result =
          await sendDevTask(device: d, prompt: 'x', port: server.port);
      expect(result.ok, isFalse);
      expect(result.error, isNot(contains('{')), reason: 'not raw JSON');
      expect(result.error, contains('disabled'));
    });
  });
}
