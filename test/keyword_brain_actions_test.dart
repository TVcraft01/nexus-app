import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/keyword_brain.dart';
import 'package:nexus_app/ai/nexus_brain.dart';

void main() {
  final brain = KeywordBrain();

  group('alarm recognition', () {
    test('set an alarm for 7 am', () async {
      final a = await brain.interpret('set an alarm for 7 am');
      expect(a.command, NexusCommand.setAlarm);
      expect(a.args['hour'], 7);
      expect(a.args['minute'], 0);
    });

    test('set an alarm at 6:30 pm', () async {
      final a = await brain.interpret('set an alarm at 6:30 pm');
      expect(a.command, NexusCommand.setAlarm);
      expect(a.args['hour'], 18);
      expect(a.args['minute'], 30);
    });

    test('set an alarm for 19:00', () async {
      final a = await brain.interpret('set an alarm for 19:00');
      expect(a.command, NexusCommand.setAlarm);
      expect(a.args['hour'], 19);
      expect(a.args['minute'], 0);
    });

    test('alarm without a time asks for one', () async {
      final a = await brain.interpret('set an alarm');
      expect(a.command, NexusCommand.setAlarm);
      expect(a.args['needsTime'], isTrue);
    });
  });

  group('timer recognition', () {
    test('set a timer for 10 minutes', () async {
      final a = await brain.interpret('set a timer for 10 minutes');
      expect(a.command, NexusCommand.setTimer);
      expect(a.args['seconds'], 600);
    });

    test('set a timer for 30 seconds', () async {
      final a = await brain.interpret('set a timer for 30 seconds');
      expect(a.command, NexusCommand.setTimer);
      expect(a.args['seconds'], 30);
    });

    test('set a timer for 2 hours', () async {
      final a = await brain.interpret('set a timer for 2 hours');
      expect(a.command, NexusCommand.setTimer);
      expect(a.args['seconds'], 7200);
    });

    test('timer without a length asks for one', () async {
      final a = await brain.interpret('set a timer');
      expect(a.command, NexusCommand.setTimer);
      expect(a.args['needsTime'], isTrue);
    });
  });

  group('Deezer Flow recognition', () {
    test('play Deezer Flow', () async {
      final a = await brain.interpret('play Deezer Flow');
      expect(a.command, NexusCommand.playDeezerFlow);
    });

    test('play my Flow on Deezer', () async {
      final a = await brain.interpret('play my flow on deezer');
      expect(a.command, NexusCommand.playDeezerFlow);
    });
  });

  group('call recognition', () {
    test('call Sam', () async {
      final a = await brain.interpret('call Sam');
      expect(a.command, NexusCommand.callContact);
      expect(a.args['target'], 'Sam');
    });

    test('call 555-1234', () async {
      final a = await brain.interpret('call 555-1234');
      expect(a.command, NexusCommand.callContact);
      expect(a.args['target'], '555-1234');
    });

    test('dial 911', () async {
      final a = await brain.interpret('dial 911');
      expect(a.command, NexusCommand.callContact);
      expect(a.args['target'], '911');
    });

    test('call with no target asks for one', () async {
      final a = await brain.interpret('call');
      expect(a.command, NexusCommand.callContact);
      expect(a.args['needsTarget'], isTrue);
    });

    test('"remind me to call Sam" stays a reminder, not a call', () async {
      final a = await brain.interpret('remind me to call Sam at 7 pm');
      expect(a.command, NexusCommand.setReminder);
    });
  });

  group('email recognition', () {
    test('check email', () async {
      final a = await brain.interpret('check email');
      expect(a.command, NexusCommand.openEmail);
    });

    test('open Gmail', () async {
      final a = await brain.interpret('open Gmail');
      expect(a.command, NexusCommand.openEmail);
    });

    test('"remind me to check email" stays a reminder, not email', () async {
      final a = await brain.interpret('remind me to check email at 5 pm');
      expect(a.command, NexusCommand.setReminder);
    });
  });

  group('navigation recognition', () {
    test('navigate to the nearest pharmacy', () async {
      final a = await brain.interpret('navigate to the nearest pharmacy');
      expect(a.command, NexusCommand.navigate);
      expect(a.args['destination'], 'the nearest pharmacy');
    });

    test('get directions to work', () async {
      final a = await brain.interpret('get directions to work');
      expect(a.command, NexusCommand.navigate);
      expect(a.args['destination'], 'work');
    });

    test('how do I get to the airport', () async {
      final a = await brain.interpret('how do I get to the airport');
      expect(a.command, NexusCommand.navigate);
      expect(a.args['destination'], 'the airport');
    });

    test('drive to 1 Main Street', () async {
      final a = await brain.interpret('drive to 1 Main Street');
      expect(a.command, NexusCommand.navigate);
      expect(a.args['destination'], '1 Main Street');
    });

    test('navigation without a destination asks for one', () async {
      final a = await brain.interpret('navigate');
      expect(a.command, NexusCommand.navigate);
      expect(a.args['needsDestination'], isTrue);
    });
  });
}
