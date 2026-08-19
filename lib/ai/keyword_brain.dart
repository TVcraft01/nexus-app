import 'nexus_brain.dart';
import 'spoken_time.dart';

/// The guaranteed-minimum offline brain: a small keyword parser that maps a
/// fixed set of phrases to actions, similar to how a simple voice assistant
/// handles basic commands. No model, no network, works on any hardware.
class KeywordBrain implements NexusBrain {
  @override
  Future<NexusAction> interpret(String input) async {
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

    if (_hasAny(t, const ['remind', 'reminder', 'alarm', 'notify'])) {
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
        reply: 'Reminder set for ${_formatTime(when)}.',
        args: {'when': when, 'message': _extractReminderMessage(input)},
      );
    }

    return NexusAction(
      command: NexusCommand.unknown,
      reply: 'Sorry, I don\'t understand that yet. Try "create a folder", '
          '"open Wi-Fi settings", or "remind me to call Sam at 7 pm".',
    );
  }

  bool _hasAny(String text, List<String> words) => words.any(text.contains);

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
  /// the caller can ask for a time when none is given.
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

  String _formatTime(DateTime when) {
    final hour12 = when.hour % 12 == 0 ? 12 : when.hour % 12;
    final minute = when.minute.toString().padLeft(2, '0');
    final meridiem = when.hour >= 12 ? 'pm' : 'am';
    return '$hour12:$minute $meridiem';
  }
}
