import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/paired_device.dart';
import '../sync/knowledge_store.dart';
import 'nexus_brain.dart';
import 'reminder_service.dart';

/// Carries out the commands the [NexusBrain] decided on, and speaks the
/// resulting reply aloud (text is always shown regardless).
class NexusActionRunner {
  final ReminderService _reminders;
  final KnowledgeStore _store;
  final Future<List<PairedDevice>> Function() _devicesProvider;
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  /// When a spoken device reference was ambiguous, this holds the unresolved
  /// candidates while Nexus waits for the user to pick one.
  ({String key, List<PairedDevice> candidates})? _pendingDevice;

  /// True when Nexus asked "Which device?" and is waiting for a name.
  bool get awaitingClarification => _pendingDevice != null;

  NexusActionRunner({
    ReminderService? reminders,
    KnowledgeStore? store,
    Future<List<PairedDevice>> Function()? devicesProvider,
  })  : _reminders = reminders ?? ReminderService(),
        _store = store ?? KnowledgeStore.instance,
        _devicesProvider = devicesProvider ?? (() async => const []);

  Future<String> run(NexusAction action) async {
    switch (action.command) {
      case NexusCommand.createFolder:
        return _createFolder(action.args['name'] as String? ?? 'New Folder');
      case NexusCommand.openWifiSettings:
        return _openWifiSettings();
      case NexusCommand.setReminder:
        return _setReminder(action);
      case NexusCommand.setPreference:
        return _setPreference(action);
      case NexusCommand.unknown:
        return action.reply;
    }
  }

  /// Attempts to resolve a pending "Which device?" answer. Returns the
  /// confirmation reply when the input named one of the candidates, or null
  /// when it didn't (the caller should then treat the input normally).
  Future<String?> answerClarification(String input) async {
    final pending = _pendingDevice;
    if (pending == null) return null;
    final chosen = _matchByName(input, pending.candidates);
    if (chosen == null) {
      _pendingDevice = null;
      return null;
    }
    await _store.addPreference(
      pending.key,
      chosen.deviceId,
      valueName: chosen.deviceName,
    );
    _pendingDevice = null;
    return 'Got it — I\'ll only notify you on ${chosen.deviceName} from now on.';
  }

  /// Stores a "notify on `device`" preference. Resolves the spoken device
  /// reference against paired devices by platform; when it's ambiguous it
  /// asks instead of guessing, and when nothing matches it says so.
  Future<String> _setPreference(NexusAction action) async {
    final key = action.args['key'] as String? ?? 'notify_device';
    final deviceRef =
        (action.args['deviceRef'] as String? ?? '').toLowerCase().trim();
    final devices = await _devicesProvider();
    final candidates = resolveDeviceReference(deviceRef, devices);

    if (candidates.isEmpty) {
      return _noMatchReply(deviceRef, devices);
    }
    if (candidates.length == 1) {
      final chosen = candidates.first;
      await _store.addPreference(
        key,
        chosen.deviceId,
        valueName: chosen.deviceName,
      );
      return 'Got it — I\'ll only notify you on ${chosen.deviceName} from now on.';
    }

    // Ambiguous: never guess — ask the user which one they meant.
    _pendingDevice = (key: key, candidates: candidates);
    final names = candidates.map((d) => d.deviceName).toList();
    final options = names.length == 2
        ? '${names[0]} or ${names[1]}'
        : names.join(', ');
    return 'Which device — $options?';
  }

  String _noMatchReply(String deviceRef, List<PairedDevice> devices) {
    if (devices.isEmpty) {
      return 'I don\'t see any paired devices to notify. Pair a device first, '
          'then tell me again.';
    }
    return 'I couldn\'t match "$deviceRef" to a paired device. Pair a device '
        'or name it directly — for example "only remind me on my phone".';
  }

  /// Matches the user's clarifying answer to one of [candidates] by name
  /// (case-insensitive, exact or substring in either direction).
  PairedDevice? _matchByName(String input, List<PairedDevice> candidates) {
    final t = input.toLowerCase().trim();
    if (t.isEmpty) return null;
    for (final d in candidates) {
      final name = d.deviceName.toLowerCase();
      if (t == name || t.contains(name) || name.contains(t)) return d;
    }
    return null;
  }

  /// Best-effort text-to-speech using the device's on-device engine. Never
  /// blocks the reply from being shown if speech is unavailable.
  Future<void> speak(String text) async {
    try {
      if (!_ttsReady) {
        await _tts.setLanguage('en-US');
        _ttsReady = true;
      }
      await _tts.speak(text);
    } catch (_) {
      // Speech is optional; the text reply is still on screen.
    }
  }

  Future<String> _createFolder(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final parent = Directory(p.join(dir.path, 'Nexus'));
    final target = _uniqueDir(Directory(p.join(parent.path, name)));
    await target.create(recursive: true);
    // One real, honest source for the shared "facts" log: record what the
    // user actually asked Nexus to do, so it propagates to paired devices.
    try {
      await _store.addFact('Created a folder named "${p.basename(target.path)}"');
    } catch (_) {
      // Knowledge logging is best-effort; the action itself already succeeded.
    }
    return 'Created folder "${p.basename(target.path)}" inside '
        '"${parent.path}".';
  }

  Directory _uniqueDir(Directory dir) {
    if (!dir.existsSync()) return dir;
    var i = 1;
    while (Directory('${dir.path} ($i)').existsSync()) {
      i++;
    }
    return Directory('${dir.path} ($i)');
  }

  Future<String> _openWifiSettings() async {
    if (Platform.isAndroid) {
      const intent = AndroidIntent(action: 'android.settings.WIFI_SETTINGS');
      await intent.launch();
      return 'Opening Wi-Fi settings…';
    }

    if (Platform.isLinux) {
      const candidates = <List<String>>[
        ['nm-connection-editor'],
        ['gnome-control-center', 'wifi'],
        ['gnome-control-center', 'network'],
      ];
      for (final command in candidates) {
        try {
          final process = await Process.start(
            command.first,
            command.length > 1 ? command.sublist(1) : const <String>[],
          );
          // Launch and return — the settings window keeps running on its own.
          unawaited(process.stdout.drain<void>());
          unawaited(process.stderr.drain<void>());
          return 'Opening Wi-Fi settings…';
        } catch (_) {
          // Command not installed; try the next candidate.
        }
      }
      return 'I couldn\'t find a Wi-Fi settings app on this system.';
    }

    return 'Opening Wi-Fi settings isn\'t supported on this device yet.';
  }

  Future<String> _setReminder(NexusAction action) async {
    if (action.args['needsTime'] == true) return action.reply;
    final when = action.args['when'] as DateTime;
    final message = action.args['message'] as String? ?? 'Reminder';
    await _reminders.scheduleReminder(when, message);
    // Record it in the knowledge log so paired devices also learn about (and
    // schedule) this reminder when they next sync. UTC keeps the absolute
    // moment intact across timezones.
    try {
      await _store.addReminder(when.toUtc(), message);
    } catch (_) {
      // The reminder is already scheduled locally; sync logging is best-effort.
    }
    return action.reply;
  }
}
