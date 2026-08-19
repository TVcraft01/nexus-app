/// Shared helpers for turning a spoken time expression into a concrete
/// [DateTime] or [Duration] using the device's own clock.
///
/// Both [KeywordBrain] (free text) and [LlmBrain] (structured model output)
/// call into these so the actual "when" is computed in Dart — never by the
/// small local model, which is unreliable at producing absolute dates/times.
library;

/// A 24-hour clock time: hour 0-23, minute 0-59.
typedef ClockTime = ({int hour, int minute});

/// Parses a duration unit word ("minutes", "hrs", "secs", ...) keyed by its
/// leading letter. Returns null for a non-positive amount or unknown unit.
Duration? durationFromParts({required int amount, required String unit}) {
  final u = unit.trim().toLowerCase();
  if (amount <= 0) return null;
  if (u.startsWith('h')) return Duration(hours: amount);
  if (u.startsWith('m')) return Duration(minutes: amount);
  if (u.startsWith('s')) return Duration(seconds: amount);
  return null;
}

/// The moment [amount] [unit]s from now. Returns null (never a past time) for
/// a non-positive or unknown duration.
DateTime? reminderTimeFromDuration({
  required int amount,
  required String unit,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final duration = durationFromParts(amount: amount, unit: unit);
  if (duration == null) return null;
  final when = clock.add(duration);
  return when.isAfter(clock) ? when : null;
}

/// The next occurrence of [hour]:[minute] on the device clock. Rolls to
/// tomorrow when that time is already past, so the result is always in the
/// future. Returns null for out-of-range values.
DateTime? reminderTimeFromClock({
  required int hour,
  required int minute,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  var when = DateTime(clock.year, clock.month, clock.day, hour, minute);
  if (!when.isAfter(clock)) when = when.add(const Duration(days: 1));
  return when;
}

/// Parses a standalone clock time such as "19:00", "7", "7:30", "7 pm", or
/// "07:30 am" into a 24-hour [ClockTime]. Returns null when it isn't one.
ClockTime? parseClockTime(String text) {
  final t = text.trim().toLowerCase();
  final match = RegExp(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$').firstMatch(t);
  if (match == null) return null;
  var hour = int.tryParse(match.group(1)!);
  if (hour == null) return null;
  final minute = int.tryParse(match.group(2) ?? '0') ?? 0;
  final meridiem = match.group(3);
  if (meridiem == 'pm' && hour < 12) hour += 12;
  if (meridiem == 'am' && hour == 12) hour = 0;
  if (hour > 23 || minute > 59) return null;
  return (hour: hour, minute: minute);
}

/// The next future occurrence of a standalone clock-time string (see
/// [parseClockTime]); null when the string isn't a valid time.
DateTime? reminderTimeFromClockString(String text, {DateTime? now}) {
  final clock = parseClockTime(text);
  if (clock == null) return null;
  return reminderTimeFromClock(hour: clock.hour, minute: clock.minute, now: now);
}
