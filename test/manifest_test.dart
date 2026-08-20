import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the two AndroidManifest fixes that were live-verified on a phone:
/// without them, "set an alarm"/"set a timer" crash on a missing permission and
/// "play Deezer Flow" reports Deezer as not installed.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('declares the AlarmClock SET_ALARM permission (alarm + timer)', () {
    expect(
      manifest,
      contains('com.android.alarm.permission.SET_ALARM'),
      reason: 'ACTION_SET_ALARM and ACTION_SET_TIMER both require it',
    );
    expect(
      manifest,
      contains(
        '<uses-permission android:name="com.android.alarm.permission.SET_ALARM"/>',
      ),
    );
  });

  test('declares Deezer visibility via its package', () {
    expect(manifest, contains('deezer.android.app'));
    expect(manifest, contains('<package android:name="deezer.android.app"/>'));
  });

  test('declares the user-consent battery optimization permission', () {
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>',
      ),
      reason: 'Nexus must declare this before opening the OS consent dialog',
    );
  });

  test('declares maps visibility for navigation intents', () {
    expect(
      manifest,
      contains('<data android:scheme="google.navigation"/>'),
      reason: 'google.navigation: starts turn-by-turn directions',
    );
    expect(manifest, contains('<data android:scheme="geo"/>'),
        reason: 'geo: is the fallback maps intent');
  });
}
