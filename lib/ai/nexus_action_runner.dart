import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../sync/knowledge_store.dart';
import 'nexus_brain.dart';
import 'reminder_service.dart';

/// Carries out the commands the [NexusBrain] decided on, and speaks the
/// resulting reply aloud (text is always shown regardless).
class NexusActionRunner {
  final ReminderService _reminders = ReminderService();
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  Future<String> run(NexusAction action) async {
    switch (action.command) {
      case NexusCommand.createFolder:
        return _createFolder(action.args['name'] as String? ?? 'New Folder');
      case NexusCommand.openWifiSettings:
        return _openWifiSettings();
      case NexusCommand.setReminder:
        return _setReminder(action);
      case NexusCommand.unknown:
        return action.reply;
    }
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
      await KnowledgeStore.instance
          .addFact('Created a folder named "${p.basename(target.path)}"');
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
      await KnowledgeStore.instance.addReminder(when.toUtc(), message);
    } catch (_) {
      // The reminder is already scheduled locally; sync logging is best-effort.
    }
    return action.reply;
  }
}
