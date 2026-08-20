import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/math_notes/math_trigger_detector.dart';

void main() {
  group('MathTriggerDetector.detect', () {
    test('matches simple addition', () {
      final r = MathTriggerDetector.detect('12+8=');
      expect(r, isNotNull);
      expect(r!.formatted, '20');
      expect(r.expression, '12+8');
    });

    test('matches simple subtraction', () {
      final r = MathTriggerDetector.detect('10-3=');
      expect(r, isNotNull);
      expect(r!.formatted, '7');
    });

    test('matches simple multiplication', () {
      final r = MathTriggerDetector.detect('6*7=');
      expect(r, isNotNull);
      expect(r!.formatted, '42');
    });

    test('matches simple division', () {
      final r = MathTriggerDetector.detect('20/4=');
      expect(r, isNotNull);
      expect(r!.formatted, '5');
    });

    test('matches negative numbers', () {
      final r = MathTriggerDetector.detect('-5+3=');
      expect(r, isNotNull);
      expect(r!.formatted, '-2');
    });

    test('matches decimal numbers', () {
      final r = MathTriggerDetector.detect('1.5+2.5=');
      expect(r, isNotNull);
      expect(r!.formatted, '4');
    });

    test('matches with whitespace', () {
      final r = MathTriggerDetector.detect('  12 + 8  =  ');
      expect(r, isNotNull);
      expect(r!.formatted, '20');
    });

    test('respects operator precedence: multiplication before addition', () {
      final r = MathTriggerDetector.detect('2+3*4=');
      expect(r, isNotNull);
      expect(r!.formatted, '14');
    });

    test('respects parentheses', () {
      final r = MathTriggerDetector.detect('(2+3)*4=');
      expect(r, isNotNull);
      expect(r!.formatted, '20');
    });

    test('returns null for empty string', () {
      expect(MathTriggerDetector.detect(''), isNull);
    });

    test('returns null for plain text', () {
      expect(MathTriggerDetector.detect('hello world'), isNull);
    });

    test('returns null for expression without =', () {
      expect(MathTriggerDetector.detect('12+8'), isNull);
    });

    test('returns null for incomplete expression', () {
      expect(MathTriggerDetector.detect('12+='), isNull);
    });

    test('returns null for expressions with letters', () {
      expect(MathTriggerDetector.detect('abc='), isNull);
    });

    test('returns null for expressions with extra operators', () {
      expect(MathTriggerDetector.detect('12++8='), isNull);
    });

    test('returns null for expressions with exponentiation', () {
      expect(MathTriggerDetector.detect('2^3='), isNull);
    });

    test('returns null for expressions with parentheses but missing close', () {
      expect(MathTriggerDetector.detect('(2+3='), isNull);
    });

    test('handles nested parentheses', () {
      final r = MathTriggerDetector.detect('((2+3))*4=');
      expect(r, isNotNull);
      expect(r!.formatted, '20');
    });

    test('formats integer results without decimals', () {
      final r = MathTriggerDetector.detect('10/2=');
      expect(r, isNotNull);
      final result = r!;
      expect(result.formatted, '5');
      expect(result.formatted, isNot(contains('.')));
    });

    test('formats decimal results with appropriate precision', () {
      final r = MathTriggerDetector.detect('10/3=');
      expect(r, isNotNull);
      expect(r!.formatted, contains('.'));
    });
  });

  group('MathResult', () {
    test('toString shows expression = formatted', () {
      const r = MathResult(expression: '12+8', value: 20, formatted: '20');
      expect(r.toString(), '12+8 = 20');
    });
  });
}
