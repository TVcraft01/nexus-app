import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/keyword_brain.dart';
import 'package:nexus_app/ai/nexus_brain.dart';
import 'package:nexus_app/ai/spoken_time.dart';

void main() {
  group('reminder time helpers', () {
    test('relative durations land in the future', () {
      final before = DateTime.now();
      final in3 = reminderTimeFromDuration(amount: 3, unit: 'minutes')!;
      final in2h = reminderTimeFromDuration(amount: 2, unit: 'hours')!;
      expect(in3.isAfter(before), isTrue);
      expect(in2h.isAfter(before), isTrue);
      expect(in3.difference(before).inMinutes, inInclusiveRange(2, 4));
      expect(in2h.difference(before).inHours, inInclusiveRange(1, 3));
    });

    test('non-positive or unknown durations are refused (never in the past)', () {
      expect(reminderTimeFromDuration(amount: 0, unit: 'minutes'), isNull);
      expect(reminderTimeFromDuration(amount: -5, unit: 'minutes'), isNull);
      expect(reminderTimeFromDuration(amount: 3, unit: 'fortnights'), isNull);
    });

    test('clock time rolls to tomorrow when already past', () {
      final now = DateTime(2026, 1, 1, 20, 0); // 8 pm
      expect(reminderTimeFromClock(hour: 19, minute: 0, now: now),
          DateTime(2026, 1, 2, 19, 0));
      expect(reminderTimeFromClock(hour: 20, minute: 0, now: now),
          DateTime(2026, 1, 2, 20, 0));
    });

    test('clock time later today stays today', () {
      final now = DateTime(2026, 1, 1, 7, 0);
      expect(reminderTimeFromClock(hour: 19, minute: 0, now: now),
          DateTime(2026, 1, 1, 19, 0));
    });

    test('parseClockTime handles 24h, 12h, and meridiem forms', () {
      expect(parseClockTime('19:00'), (hour: 19, minute: 0));
      expect(parseClockTime('7 pm'), (hour: 19, minute: 0));
      expect(parseClockTime('7:30am'), (hour: 7, minute: 30));
      expect(parseClockTime('12 am'), (hour: 0, minute: 0));
      expect(parseClockTime('12 pm'), (hour: 12, minute: 0));
      expect(parseClockTime('25:00'), isNull);
    });
  });

  group('KeywordBrain reminder recognition', () {
    final brain = KeywordBrain();

    test('"remind me in 3 minutes" computes a future time in Dart', () async {
      final action = await brain.interpret('remind me in 3 minutes');
      expect(action.command, NexusCommand.setReminder);
      final when = action.args['when'] as DateTime;
      expect(when.isAfter(DateTime.now()), isTrue);
      expect(when.difference(DateTime.now()).inMinutes, inInclusiveRange(2, 4));
    });

    test('"remind me in 2 hours" computes a future time in Dart', () async {
      final action = await brain.interpret('remind me to stretch in 2 hours');
      expect(action.command, NexusCommand.setReminder);
      final when = action.args['when'] as DateTime;
      expect(when.isAfter(DateTime.now()), isTrue);
      expect(when.difference(DateTime.now()).inHours, inInclusiveRange(1, 3));
    });

    test('"remind me at 7pm" resolves to the next 7 pm', () async {
      final action = await brain.interpret('remind me to call Sam at 7pm');
      expect(action.command, NexusCommand.setReminder);
      final when = action.args['when'] as DateTime;
      expect(when.hour, 19);
      expect(when.isAfter(DateTime.now()), isTrue);
    });
  });
}
