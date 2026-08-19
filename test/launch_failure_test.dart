import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/nexus_action_runner.dart';

void main() {
  group('describeLaunchFailure', () {
    test('extracts the system denial reason from a PlatformException', () {
      final reason = describeLaunchFailure(PlatformException(
        code: 'error',
        message: 'Permission Denial: starting Intent { act='
            'android.intent.action.SET_ALARM ... } requires '
            'com.android.alarm.permission.SET_ALARM',
      ));
      expect(reason, contains('Permission Denial'));
      expect(reason, contains('SET_ALARM'));
    });

    test('falls back to the error code when there is no message', () {
      expect(
        describeLaunchFailure(PlatformException(code: 'missing_plugin')),
        'missing_plugin',
      );
    });

    test('falls back to toString for a plain exception', () {
      expect(describeLaunchFailure(Exception('boom')), contains('boom'));
    });

    test('never returns an empty reason', () {
      expect(describeLaunchFailure(PlatformException(code: '')), isNotEmpty);
    });
  });
}
