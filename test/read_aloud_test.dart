import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/read_aloud/read_aloud_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReadAloudService', () {
    test('isSpeaking starts as false', () {
      expect(ReadAloudService.instance.isSpeaking.value, false);
    });

    test('currentText starts as null', () {
      expect(ReadAloudService.instance.currentText, null);
    });

    test('stop sets isSpeaking to false', () async {
      // Even if not speaking, stop should not throw
      await ReadAloudService.instance.stop();
      expect(ReadAloudService.instance.isSpeaking.value, false);
    });

    test('init does not throw on non-Android platforms', () {
      // On test runner (Linux/macOS), init should be a no-op
      ReadAloudService.instance.init();
      // No assertion needed — just ensuring no crash
    });
  });
}
