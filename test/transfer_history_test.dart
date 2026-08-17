import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/transfer/files_screen.dart';
import 'package:nexus_app/transfer/transfer_service.dart';

void main() {
  group('TransferRecord', () {
    test('serializes and deserializes both directions', () {
      final record = TransferRecord(
        direction: TransferDirection.sent,
        fileName: 'notes.txt',
        sizeBytes: 1024,
        otherDeviceName: 'phone',
        timestamp: DateTime(2026, 8, 17, 12, 30),
        localPath: '/tmp/notes.txt',
      );
      final json = record.toJson();
      final restored = TransferRecord.fromJson(json);

      expect(restored.direction, TransferDirection.sent);
      expect(restored.fileName, 'notes.txt');
      expect(restored.sizeBytes, 1024);
      expect(restored.otherDeviceName, 'phone');
      expect(restored.timestamp, DateTime(2026, 8, 17, 12, 30));
      expect(restored.localPath, '/tmp/notes.txt');
      expect(restored.isSent, isTrue);
    });

    test('received records are not sent', () {
      final record = TransferRecord(
        direction: TransferDirection.received,
        fileName: 'photo.jpg',
        sizeBytes: 10,
        otherDeviceName: 'linux',
        timestamp: DateTime(2026, 8, 17),
        localPath: '/tmp/photo.jpg',
      );
      expect(record.isSent, isFalse);
    });
  });

  group('relativeTime', () {
    final now = DateTime(2026, 8, 17, 12, 0);

    test('under a minute is "just now"', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 30)), now: now),
          'just now');
    });

    test('minutes', () {
      expect(relativeTime(now.subtract(const Duration(minutes: 2)), now: now),
          '2 minutes ago');
      expect(relativeTime(now.subtract(const Duration(minutes: 1)), now: now),
          '1 minute ago');
    });

    test('hours', () {
      expect(relativeTime(now.subtract(const Duration(hours: 5)), now: now),
          '5 hours ago');
      expect(relativeTime(now.subtract(const Duration(hours: 1)), now: now),
          '1 hour ago');
    });

    test('days', () {
      expect(relativeTime(now.subtract(const Duration(days: 3)), now: now),
          '3 days ago');
    });

    test('older than a week falls back to a short date', () {
      final old = DateTime(2026, 8, 1, 9, 5);
      expect(relativeTime(old, now: now), '1/8/2026');
    });
  });

  group('humanSize', () {
    test('formats sizes across units', () {
      expect(humanSize(512), '512 B');
      expect(humanSize(2048), '2.0 KB');
      expect(humanSize(3 * 1024 * 1024), '3.0 MB');
      expect(humanSize(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });
}
