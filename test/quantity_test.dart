import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/quantity.dart';

// Pull-request validation exercises the current feature-branch code.
void main() {
  group('Quantity.parse', () {
    test('parses whole and fractional values exactly', () {
      expect(Quantity.parse('1'), 1000);
      expect(Quantity.parse('1.5'), 1500);
      expect(Quantity.parse('0.75'), 750);
      expect(Quantity.parse('0.001'), 1);
      expect(Quantity.parse('2,125'), 2125);
    });

    test('supports signed stock movement values only when requested', () {
      expect(Quantity.parse('-1.25', allowNegative: true), -1250);
      expect(Quantity.parse('-1.25'), isNull);
      expect(Quantity.parse('+2.5'), 2500);
    });

    test('rejects malformed values and precision beyond three places', () {
      for (final value in ['', '.', '1.', '1.2345', '1..2', 'abc', '1,2.3']) {
        expect(Quantity.parse(value), isNull, reason: value);
      }
    });

    test('whole-only units reject non-zero fractions', () {
      expect(Quantity.parse('2', allowsFraction: false), 2000);
      expect(Quantity.parse('2.000', allowsFraction: false), 2000);
      expect(Quantity.parse('2.1', allowsFraction: false), isNull);
    });

    test('rejects excessive values', () {
      expect(Quantity.parse('1000000000'), isNull);
    });
  });

  group('Quantity.format', () {
    test('removes insignificant trailing zeroes', () {
      expect(Quantity.format(1000), '1');
      expect(Quantity.format(1500), '1.5');
      expect(Quantity.format(750), '0.75');
      expect(Quantity.format(1), '0.001');
      expect(Quantity.format(-1250), '-1.25');
    });
  });

  group('Quantity.lineTotalMinor', () {
    test('uses half-up piastre rounding', () {
      expect(Quantity.lineTotalMinor(unitPriceMinor: 100, quantityScaled: 1500), 150);
      expect(Quantity.lineTotalMinor(unitPriceMinor: 1, quantityScaled: 500), 1);
      expect(Quantity.lineTotalMinor(unitPriceMinor: 0, quantityScaled: 1500), 0);
    });
  });
}
