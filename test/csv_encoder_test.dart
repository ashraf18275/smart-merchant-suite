import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/csv_encoder.dart';

void main() {
  test('encodes commas, quotes, newlines and Arabic with a UTF-8 BOM', () {
    final csv = encodeCsv([
      ['name', 'description', 'amount'],
      ['شاحن', 'خصم, خاص', 1250],
      ['سماعة', 'قال "ممتاز"\nجديد', 300],
    ]);

    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv, contains('شاحن,"خصم, خاص",1250'));
    expect(csv, contains('"قال ""ممتاز""\nجديد",300'));
    expect(csv, contains('\r\n'));
  });

  test('encodes null values as empty cells and always ends with a row break', () {
    final csv = encodeCsv([
      ['id', 'sku'],
      [1, null],
    ]);

    expect(csv, contains('1,'));
    expect(csv.endsWith('\r\n'), isTrue);
  });
}
