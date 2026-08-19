import 'action_registry.dart';
import 'nexus_brain.dart';
import 'spoken_time.dart';

/// The guaranteed-minimum offline brain: a small keyword parser that maps a
/// fixed set of phrases to actions, similar to how a simple voice assistant
/// handles basic commands. No model, no network, works on any hardware.
class KeywordBrain implements NexusBrain {
  @override
  Future<NexusAction> interpret(String input) async {
    final action = await _interpretUnchecked(input);
    if (action.command != NexusCommand.unknown &&
        !ActionRegistry.instance.isEnabled(action.command)) {
      return NexusAction(
        command: NexusCommand.unknown,
        reply: disabledActionReply(action.command),
      );
    }
    return action;
  }

  /// The raw pattern matching, before the action-registry gate above. Kept
  /// separate so a turned-off action is skipped rather than matched and then
  /// executed anyway.
  Future<NexusAction> _interpretUnchecked(String input) async {
    final t = input.toLowerCase().trim();

    if (_hasAny(t, const ['folder', 'directory'])) {
      return NexusAction(
        command: NexusCommand.createFolder,
        reply: 'Creating a folder.',
        args: {'name': _extractFolderName(input)},
      );
    }

    if (_hasAny(t, const ['wifi', 'wi-fi', 'wi fi', 'wireless'])) {
      return const NexusAction(
        command: NexusCommand.openWifiSettings,
        reply: 'Opening Wi-Fi settings.',
      );
    }

    // Preference must come before the reminder branch: "only remind me on my
    // phone" contains "remind" but means "change which device notifies", not
    // "set a reminder".
    final notifyDevice = _extractNotifyDevicePreference(input);
    if (notifyDevice != null) {
      return NexusAction(
        command: NexusCommand.setPreference,
        reply: 'Got it.', // the runner confirms with the resolved device name
        args: {'key': 'notify_device', 'deviceRef': notifyDevice},
      );
    }

    // Reminder comes before the alarm/call/email branches so phrases like
    // "remind me to call Sam at 7 pm" or "remind me to check email" still mean
    // "set a reminder", not the new actions.
    if (_hasAny(t, const ['remind', 'reminder', 'notify'])) {
      final when = _parseReminderTime(input);
      if (when == null) {
        return NexusAction(
          command: NexusCommand.setReminder,
          reply: 'When should I remind you? Try "remind me in 30 minutes" '
              'or "remind me to call Sam at 7 pm".',
          args: const {'needsTime': true},
        );
      }
      return NexusAction(
        command: NexusCommand.setReminder,
        reply: 'Reminder set for ${_formatClock(when.hour, when.minute)}.',
        args: {'when': when, 'message': _extractReminderMessage(input)},
      );
    }

    // "set an alarm" is its own action (handed to the native Clock app),
    // distinct from "remind me ..." reminders.
    if (_hasWord(t, 'alarm')) {
      final when = _parseAlarmClock(input);
      if (when == null) {
        return NexusAction(
          command: NexusCommand.setAlarm,
          reply: 'What time should I set the alarm for? Try '
              '"set an alarm for 7 am".',
          args: const {'needsTime': true},
        );
      }
      return NexusAction(
        command: NexusCommand.setAlarm,
        reply: 'Opening your Clock app to set an alarm for '
            '${_formatClock(when.hour, when.minute)}…',
        args: {'hour': when.hour, 'minute': when.minute},
      );
    }

    if (_hasAny(t, const ['timer', 'countdown'])) {
      final seconds = _parseTimerSeconds(input);
      if (seconds == null) {
        return NexusAction(
          command: NexusCommand.setTimer,
          reply: 'How long should I set the timer for? Try '
              '"set a timer for 10 minutes".',
          args: const {'needsTime': true},
        );
      }
      return NexusAction(
        command: NexusCommand.setTimer,
        reply: 'Opening your Clock app to set a ${_formatDuration(seconds)} '
            'timer…',
        args: {'seconds': seconds},
      );
    }

    if (t.contains('flow') && (t.contains('deezer') || t.contains('play'))) {
      return const NexusAction(
        command: NexusCommand.playDeezerFlow,
        reply: 'Opening Deezer Flow…',
      );
    }

    if (_hasWord(t, 'call') || _hasWord(t, 'dial')) {
      final target = _extractCallTarget(input);
      if (target == null || target.isEmpty) {
        return NexusAction(
          command: NexusCommand.callContact,
          reply: 'Who should I call? Say a name or a number — for example '
              '"call Sam".',
          args: const {'needsTarget': true},
        );
      }
      return NexusAction(
        command: NexusCommand.callContact,
        reply: 'Opening your dialer for $target…',
        args: {'target': target},
      );
    }

    if (_hasAny(t, const ['email', 'gmail', 'inbox'])) {
      return const NexusAction(
        command: NexusCommand.openEmail,
        reply: 'Opening your email app…',
      );
    }

    return NexusAction(
      command: NexusCommand.unknown,
      reply: 'Sorry, I don\'t understand that yet. Try "create a folder", '
          '"open Wi-Fi settings", or "remind me to call Sam at 7 pm".',
    );
  }

  bool _hasAny(String text, List<String> words) => words.any(text.contains);

  /// Word-boundary match, used where a substring match would be risky
  /// ("call" inside "recall", for example).
  bool _hasWord(String text, String word) =>
      RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(text);

  /// Recognizes "notify/remind me (only/always) on my `device`" and
  /// "notifications only on my `device`" as a notify-device preference.
  /// Returns the device reference word ("phone", "pc", ...) or null when the
  /// phrase isn't about choosing where notifications go.
  ///
  /// Deliberately does NOT match "remind me to X on my phone" — that's a
  /// reminder with a message, not a preference.
  String? _extractNotifyDevicePreference(String input) {
    final t = input.toLowerCase();
    final match = RegExp(
      r'(?:(?:only|always|just)\s+)?(?:remind|notify|notifications?|reminders?|alerts?)'
      r'(?:\s+me)?(?:\s+(?:only|always|just))?\s+on\s+my\s+(\w+)',
    ).firstMatch(t);
    if (match == null) return null;
    final device = match.group(1)!;
    if (!const {'phone', 'pc', 'laptop', 'computer', 'desktop', 'tablet'}
        .contains(device)) {
      return null;
    }
    return device;
  }

  String _extractFolderName(String input) {
    final match = RegExp(
      r'(?:named|called)\s+(.+?)(?:\s+in\s+.+)?$',
      caseSensitive: false,
    ).firstMatch(input);
    final name = match?.group(1)?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'New Folder';
  }

  String _extractReminderMessage(String input) {
    var s = input.replaceFirst(
      RegExp(r'^.*?\bremind\s+me\s+to\s+', caseSensitive: false),
      '',
    );
    s = s.replaceFirst(
      RegExp(r'\s+(at|in)\s+.+$', caseSensitive: false),
      '',
    );
    s = s.trim();
    return s.isEmpty ? 'Reminder' : s;
  }

  /// Understands "in 30 minutes" and "at 7 pm" / "at 19:30". Returns null so
  /// the caller can ask for a time when none is given. The real timestamp is
  /// computed in Dart (see lib/ai/spoken_time.dart), never by a model.
  DateTime? _parseReminderTime(String input) {
    final t = input.toLowerCase();

    final inMatch =
        RegExp(r'\bin\s+(\d+)\s*(minutes?|mins?|hours?|hrs?)').firstMatch(t);
    if (inMatch != null) {
      final n = int.tryParse(inMatch.group(1)!);
      if (n == null) return null;
      return reminderTimeFromDuration(amount: n, unit: inMatch.group(2)!);
    }

    final atMatch =
        RegExp(r'\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?').firstMatch(t);
    if (atMatch != null) {
      var hour = int.tryParse(atMatch.group(1)!);
      if (hour == null) return null;
      final minute = int.tryParse(atMatch.group(2) ?? '0') ?? 0;
      final meridiem = atMatch.group(3);
      if (meridiem == 'pm' && hour < 12) hour += 12;
      if (meridiem == 'am' && hour == 12) hour = 0;
      return reminderTimeFromClock(hour: hour, minute: minute);
    }

    return null;
  }

  /// Extracts a clock time ("7", "7:30", "7 am", "19:00") from an alarm
  /// phrase. Returns null so the caller can ask for a time when none is given.
  ClockTime? _parseAlarmClock(String input) {
    final t = input.toLowerCase();
    final match =
        RegExp(r'\b\d{1,2}(?::\d{2})?\s*(?:am|pm)?\b').firstMatch(t);
    if (match == null) return null;
    return parseClockTime(match.group(0)!);
  }

  /// Extracts a timer length ("10 minutes", "30 seconds", "2 hours") in
  /// seconds. Returns null so the caller can ask for a length when none given.
  int? _parseTimerSeconds(String input) {
    final t = input.toLowerCase();
    final match = RegExp(r'\b(\d+)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)')
        .firstMatch(t);
    if (match == null) return null;
    final n = int.tryParse(match.group(1)!);
    if (n == null) return null;
    return durationFromParts(amount: n, unit: match.group(2)!)?.inSeconds;
  }

  /// Pulls the name or number to call out of "call Sam" / "dial 911". Stops
  /// at a trailing time clause ("at 7 pm") so it doesn't leak into the target.
  String? _extractCallTarget(String input) {
    var s = input.replaceFirst(
      RegExp(r'^\W*(?:call|dial)\b\s*(?:me\s+)?', caseSensitive: false),
      '',
    );
    s = s.replaceFirst(
      RegExp(r'\s+(?:at|in|on|for)\s+.+$', caseSensitive: false),
      '',
    );
    return s.trim();
  }

  String _formatClock(int hour, int minute) {
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    final meridiem = hour >= 12 ? 'pm' : 'am';
    final mm = minute.toString().padLeft(2, '0');
    return '$hour12:$mm $meridiem';
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (seconds % 3600 == 0) return '$hours hour${hours == 1 ? '' : 's'}';
    if (seconds % 60 == 0) return '$minutes minute${minutes == 1 ? '' : 's'}';
    if (hours > 0) {
      return '$hours hour${hours == 1 ? '' : 's'} '
          '$minutes minute${minutes == 1 ? '' : 's'}';
    }
    return '$seconds seconds';
  }
}
