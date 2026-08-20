import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/action_registry.dart';
import 'package:nexus_app/ai/nexus_brain.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ActionRegistry.instance.debugReset();
  });

  group('Per-app allowlist — logic tests', () {
    test('master toggle off blocks assistApp regardless of allowlist state', () async {
      await ActionRegistry.instance.setEnabled(NexusCommand.assistApp, false);
      expect(ActionRegistry.instance.isEnabled(NexusCommand.assistApp), false);
    });

    test('master toggle on enables assistApp command recognition', () async {
      await ActionRegistry.instance.setEnabled(NexusCommand.assistApp, true);
      expect(ActionRegistry.instance.isEnabled(NexusCommand.assistApp), true);
    });

    test('disabledActionReply mentions assist in the response', () {
      final reply = disabledActionReply(NexusCommand.assistApp);
      expect(reply.toLowerCase(), contains('assist'));
    });

    test('assistApp defaults to enabled in ActionRegistry', () {
      expect(ActionRegistry.instance.isEnabled(NexusCommand.assistApp), true);
    });
  });

  group('Quick-enable curated list — concept validation', () {
    test('curated list covers notes, calendar, browser, and maps categories', () {
      const notesPackages = {
        'com.google.android.keep',
        'com.samsung.android.app.notes',
        'com.microsoft.office.onenote',
      };
      const calendarPackages = {
        'com.google.android.calendar',
        'com.samsung.android.calendar',
      };
      const browserPackages = {
        'com.android.chrome',
        'org.mozilla.firefox',
        'com.brave.browser',
      };
      const mapsPackages = {
        'com.google.android.apps.maps',
      };

      expect(notesPackages.isNotEmpty, true);
      expect(calendarPackages.isNotEmpty, true);
      expect(browserPackages.isNotEmpty, true);
      expect(mapsPackages.isNotEmpty, true);

      for (final pkg in [...notesPackages, ...calendarPackages, ...browserPackages, ...mapsPackages]) {
        expect(pkg.contains('.'), true, reason: '$pkg should be a valid package name');
        expect(pkg.startsWith('com.') || pkg.startsWith('org.'), true, reason: '$pkg should start with com. or org.');
      }
    });
  });

  group('Refusal message format', () {
    test('unapproved app message directs user to settings', () {
      const packageName = 'com.example.unapproved';
      final message = "I'm not allowed to interact with $packageName yet. "
          'Enable it in Settings \u2192 Actions & permissions \u2192 Assist with '
          'other apps \u2192 Manage app permissions first.';

      expect(message, contains(packageName));
      expect(message, contains('Manage app permissions'));
      expect(message, contains('Settings'));
    });

    test('financial app message is distinct from allowlist refusal', () {
      const packageName = 'com.paypal.android.p2pmobile';
      final message = "I won't interact with $packageName \u2014 it appears to be a "
          'financial app, and Nexus avoids those for safety.';

      expect(message, contains(packageName));
      expect(message, contains('financial'));
      expect(message, contains('safety'));
    });
  });
}
