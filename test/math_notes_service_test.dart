import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/math_notes/math_notes_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// These tests pin the Dart -> native platform-channel contract for the
/// math-notes toggle. The regression it guards: MathNotesService sends
/// `setMathNotesEnabled` on `com.example.nexus_app/math_notes`, and the Kotlin
/// side must register a handler on THAT exact channel (the earlier bug had the
/// handler registered on the accessibility channel instead, producing a
/// MissingPluginException on launch).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.nexus_app/math_notes');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Force the Android path so the real channel call is exercised regardless
    // of the host platform the test runs on.
    MathNotesService.debugIsAndroid = true;
  });

  tearDown(() {
    MathNotesService.debugIsAndroid = false;
  });

  List<MethodCall> captureCalls() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    return calls;
  }

  Future<void> waitForCall(List<MethodCall> calls, String method) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (calls.any((c) => c.method == method)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('No $method call was sent on $channel within 2s');
  }

  test('enabling the toggle sends setMathNotesEnabled on the math_notes channel',
      () async {
    final calls = captureCalls();

    await MathNotesService.instance.setEnabled(true);
    await waitForCall(calls, 'setMathNotesEnabled');

    final call =
        calls.firstWhere((c) => c.method == 'setMathNotesEnabled');
    expect(call.arguments, {'enabled': true});
  });

  test('disabling the toggle sends setMathNotesEnabled with enabled=false',
      () async {
    final calls = captureCalls();

    await MathNotesService.instance.setEnabled(false);
    await waitForCall(calls, 'setMathNotesEnabled');

    final call =
        calls.firstWhere((c) => c.method == 'setMathNotesEnabled');
    expect(call.arguments, {'enabled': false});
  });

  test('setting persists the toggle state in SharedPreferences', () async {
    captureCalls();

    await MathNotesService.instance.setEnabled(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('nexus_math_notes_enabled'), true);

    await MathNotesService.instance.setEnabled(false);
    expect(prefs.getBool('nexus_math_notes_enabled'), false);
  });
}
