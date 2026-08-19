import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/action_registry.dart';
import 'package:nexus_app/ai/command_help_screen.dart';
import 'package:nexus_app/ai/keyword_brain.dart';
import 'package:nexus_app/ai/nexus_action_runner.dart';
import 'package:nexus_app/ai/nexus_brain.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ActionRegistry.instance.debugReset();
  });

  test('every action defaults to enabled', () {
    for (final def in nexusActions) {
      expect(ActionRegistry.instance.isEnabled(def.command), isTrue,
          reason: '${def.title} should default to on');
    }
  });

  test('setEnabled persists and isEnabled reflects it', () async {
    final prefs = await SharedPreferences.getInstance();
    await ActionRegistry.instance.setEnabled(NexusCommand.setTimer, false);
    expect(ActionRegistry.instance.isEnabled(NexusCommand.setTimer), isFalse);
    expect(prefs.getBool('nexus_action_enabled_setTimer'), isFalse);
  });

  test('init restores a persisted off switch', () async {
    SharedPreferences.setMockInitialValues(
        {'nexus_action_enabled_setTimer': false});
    await ActionRegistry.instance.init();
    expect(ActionRegistry.instance.isEnabled(NexusCommand.setTimer), isFalse);
  });

  group('KeywordBrain skips a disabled action', () {
    test('a turned-off alarm is no longer recognized', () async {
      await ActionRegistry.instance.setEnabled(NexusCommand.setAlarm, false);
      final action = await KeywordBrain().interpret('set an alarm for 7 am');
      expect(action.command, NexusCommand.unknown);
      expect(action.reply, contains('turned off'));
    });

    test('other actions still work', () async {
      await ActionRegistry.instance.setEnabled(NexusCommand.setAlarm, false);
      final action = await KeywordBrain().interpret('set a timer for 10 min');
      expect(action.command, NexusCommand.setTimer);
    });
  });

  group('LLM schema excludes disabled actions', () {
    test('a disabled token is removed but chat stays', () async {
      await ActionRegistry.instance
          .setEnabled(NexusCommand.playDeezerFlow, false);
      final tokens = enabledActionTokens();
      expect(tokens, isNot(contains('playDeezerFlow')));
      expect(tokens, contains('chat'));
      expect(tokens, contains('setAlarm'));
    });
  });

  group('help screen hides disabled actions', () {
    test('a turned-off action disappears from the visible entries', () async {
      await ActionRegistry.instance.setEnabled(NexusCommand.openEmail, false);
      final entries = visibleHelpEntries();
      expect(entries.any((e) => e.command == NexusCommand.openEmail), isFalse);
      expect(entries.any((e) => e.command == NexusCommand.setReminder), isTrue);
    });
  });

  group('NexusActionRunner refuses a disabled action', () {
    test('run returns the disabled reply instead of executing', () async {
      await ActionRegistry.instance
          .setEnabled(NexusCommand.createFolder, false);
      final runner = NexusActionRunner(devicesProvider: () async => const []);
      final reply = await runner.run(const NexusAction(
        command: NexusCommand.createFolder,
        reply: 'Creating a folder.',
        args: {'name': 'test'},
      ));
      expect(reply, contains('turned off'));
      expect(reply, contains('Create a folder'));
    });
  });
}
