import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
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
      case NexusCommand.setAlarm:
        return _setAlarm(action);
      case NexusCommand.setTimer:
        return _setTimer(action);
      case NexusCommand.playDeezerFlow:
        return _playDeezerFlow();
      case NexusCommand.callContact:
        return _callContact(action);
      case NexusCommand.openEmail:
        return _openEmail();
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
    // Safety: never schedule (or log) a reminder whose computed time is
    // already in the past — ask for a fresh time instead.
    if (!when.isAfter(DateTime.now())) {
      return 'That time is already in the past — when should I remind you? '
          'Try "remind me in 30 minutes" or "remind me at 7 pm".';
    }
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

  /// Hands an alarm to the native Clock app (Android only).
  Future<String> _setAlarm(NexusAction action) async {
    if (!Platform.isAndroid) {
      return 'Alarms aren\'t available on this platform yet — on Android I\'d '
          'hand this to your Clock app.';
    }
    final hour = action.args['hour'] as int?;
    final minute = action.args['minute'] as int? ?? 0;
    if (hour == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return 'What time should I set the alarm for? Try '
          '"set an alarm for 7 am".';
    }
    final intent = AndroidIntent(
      action: 'android.intent.action.SET_ALARM',
      arguments: {
        'android.intent.extra.alarm.HOUR': hour,
        'android.intent.extra.alarm.MINUTES': minute,
      },
    );
    final resolvable = await intent.canResolveActivity();
    if (resolvable != true) {
      return 'I couldn\'t find a Clock app to set an alarm on this device.';
    }
    await intent.launch();
    return action.reply;
  }

  /// Hands a timer to the native Clock app (Android only).
  Future<String> _setTimer(NexusAction action) async {
    if (!Platform.isAndroid) {
      return 'Timers aren\'t available on this platform yet — on Android I\'d '
          'hand this to your Clock app.';
    }
    final seconds = action.args['seconds'] as int?;
    if (seconds == null || seconds <= 0) {
      return 'How long should I set the timer for? Try '
          '"set a timer for 10 minutes".';
    }
    final intent = AndroidIntent(
      action: 'android.intent.action.SET_TIMER',
      arguments: {
        'android.intent.extra.alarm.LENGTH': seconds,
      },
    );
    final resolvable = await intent.canResolveActivity();
    if (resolvable != true) {
      return 'I couldn\'t find a Clock app to set a timer on this device.';
    }
    await intent.launch();
    return action.reply;
  }

  /// Opens Deezer at Flow via its deep link, on Android and Linux (when the
  /// app is installed). Reports honestly when it isn't.
  Future<String> _playDeezerFlow() async {
    const deezerFlow = 'deezer://www.deezer.com/flow';

    if (Platform.isAndroid) {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: deezerFlow,
      );
      final resolvable = await intent.canResolveActivity();
      if (resolvable != true) {
        return 'Deezer isn\'t installed on this device.';
      }
      await intent.launch();
      return 'Opening Deezer Flow…';
    }

    if (Platform.isLinux) {
      try {
        final process = await Process.start('xdg-open', [deezerFlow]);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        final code = await process.exitCode;
        if (code != 0) return 'Deezer isn\'t installed on this device.';
        return 'Opening Deezer Flow…';
      } catch (_) {
        return 'Deezer isn\'t installed on this device.';
      }
    }

    return 'Playing Deezer Flow isn\'t supported on this device yet.';
  }

  /// Opens the dialer pre-filled with a number (never places the call itself).
  /// Names are resolved via contacts, requesting READ_CONTACTS just-in-time.
  Future<String> _callContact(NexusAction action) async {
    final target = (action.args['target'] as String? ?? '').trim();
    if (target.isEmpty) return 'Who should I call? Say a name or a number.';
    if (!Platform.isAndroid) {
      return 'Calling isn\'t available on this platform yet — on Android I\'d '
          'open the dialer for you (without placing the call myself).';
    }

    if (_looksLikePhoneNumber(target)) {
      return _dial(target);
    }

    // Ask for contacts access only at the moment it's first needed.
    try {
      final status =
          await FlutterContacts.permissions.request(PermissionType.read);
      if (status != PermissionStatus.granted) {
        return 'I need contacts access to look up "$target". Say the number '
            'instead — for example "call 555 1234".';
      }
      final contacts = await FlutterContacts.getAll(
        properties: const {ContactProperty.name, ContactProperty.phone},
        filter: ContactFilter.name(target),
        limit: 20,
      );
      final number = _bestMatchNumber(target, contacts);
      if (number == null) {
        return 'I couldn\'t find "$target" in your contacts. Say the number '
            'instead.';
      }
      return await _dial(number);
    } catch (_) {
      return 'I couldn\'t read your contacts. Say the number instead — for '
          'example "call 555 1234".';
    }
  }

  Future<String> _dial(String number) async {
    final clean = number.replaceAll(RegExp(r'\s+'), '');
    final intent = AndroidIntent(
      action: 'android.intent.action.DIAL',
      data: 'tel:$clean',
    );
    final resolvable = await intent.canResolveActivity();
    if (resolvable != true) {
      return 'I couldn\'t find a dialer app on this device.';
    }
    await intent.launch();
    return 'Opening your dialer for $number — tap call when you\'re ready.';
  }

  /// True when [target] is a phone number (digits plus the usual separators),
  /// so it can be dialed directly without touching contacts.
  bool _looksLikePhoneNumber(String target) {
    final t = target.trim();
    if (t.isEmpty) return false;
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return false;
    return RegExp(r'^\+?[0-9\s().\-]+$').hasMatch(t);
  }

  /// Resolves [target] to a phone number without guessing: an exact display
  /// name wins, a single unique partial match is accepted, anything ambiguous
  /// or unmatched returns null.
  String? _bestMatchNumber(String target, List<Contact> contacts) {
    final t = target.trim().toLowerCase();
    Contact? exactWithPhone;
    final partialWithPhone = <Contact>[];
    for (final c in contacts) {
      final name = (c.displayName ?? '').trim().toLowerCase();
      if (name.isEmpty || c.phones.isEmpty) continue;
      if (name == t) {
        exactWithPhone ??= c;
      } else if (name.contains(t) || t.contains(name)) {
        partialWithPhone.add(c);
      }
    }
    if (exactWithPhone != null) return exactWithPhone.phones.first.number;
    if (partialWithPhone.length == 1) {
      return partialWithPhone.first.phones.first.number;
    }
    return null;
  }

  /// Opens the default email app (falling back to Gmail). This only opens the
  /// app — it never reads or connects to any account.
  Future<String> _openEmail() async {
    if (!Platform.isAndroid) {
      return 'Opening email isn\'t available on this platform yet.';
    }
    const generic = AndroidIntent(
      action: 'android.intent.action.MAIN',
      category: 'android.intent.category.APP_EMAIL',
    );
    if (await generic.canResolveActivity() == true) {
      await generic.launch();
      return 'Opening your email app…';
    }
    const gmail = AndroidIntent(
      action: 'android.intent.action.MAIN',
      category: 'android.intent.category.APP_EMAIL',
      package: 'com.google.android.gm',
    );
    if (await gmail.canResolveActivity() == true) {
      await gmail.launch();
      return 'Opening Gmail…';
    }
    return 'I couldn\'t find an email app on this device.';
  }
}
