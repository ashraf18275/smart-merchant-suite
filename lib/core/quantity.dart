/// Exact quantity parsing and formatting for inventory values.
///
/// Database and domain quantities are integer thousandths. Never use binary
/// floating point for stock, sale, transfer, or movement quantities.
abstract final class Quantity {
  static const int scale = 1000;
  static const int maxWholeValue = 999999999;

  /// Parses decimal text to integer thousandths.
  ///
  /// Returns null for malformed input, more than three fractional digits,
  /// overflow, or a fractional value when [allowsFraction] is false.
  static int? parse(
    String input, {
    bool allowsFraction = true,
    bool allowNegative = false,
  }) {
    final normalized = input.trim().replaceAll(',', '.');
    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d{1,3}))?$')
        .firstMatch(normalized);
    if (match == null) return null;

    final negative = match.group(1) == '-';
    if (negative && !allowNegative) return null;
    final whole = int.tryParse(match.group(2)!);
    if (whole == null || whole > maxWholeValue) return null;

    final fractionText = match.group(3) ?? '';
    if (!allowsFraction && fractionText.isNotEmpty &&
        int.tryParse(fractionText) != 0) {
      return null;
    }
    final fraction = int.parse(fractionText.padRight(3, '0'));
    final scaled = whole * scale + fraction;
    return negative ? -scaled : scaled;
  }

  /// Formats integer thousandths without trailing zeroes.
  static String format(int scaled) {
    final negative = scaled < 0;
    final absolute = scaled.abs();
    final whole = absolute ~/ scale;
    final fraction = absolute % scale;
    if (fraction == 0) return '${negative ? '-' : ''}$whole';
    final fractionText = fraction.toString().padLeft(3, '0').replaceFirst(
      RegExp(r'0+$'),
      '',
    );
    return '${negative ? '-' : ''}$whole.$fractionText';
  }

  /// Calculates a line total in piastres using half-up rounding.
  static int lineTotalMinor({
    required int unitPriceMinor,
    required int quantityScaled,
  }) {
    if (unitPriceMinor < 0 || quantityScaled < 0) {
      throw ArgumentError('Price and quantity must be non-negative.');
    }
    return (unitPriceMinor * quantityScaled + scale ~/ 2) ~/ scale;
  }
}
