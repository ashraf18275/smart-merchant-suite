import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/expense_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ExpenseRepository expenses;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    expenses = ExpenseRepository(db);
  });
  tearDown(() async => db.close());

  test('records a valid expense with trimmed text', () async {
    final id = await expenses.add(
      description: '  فاتورة كهرباء  ',
      category: '  مرافق  ',
      amountMinor: 12500,
    );
    final row = (await db.query('expenses', where: 'id = ?', whereArgs: [id])).single;
    expect(row['description'], 'فاتورة كهرباء');
    expect(row['category'], 'مرافق');
    expect(row['amount_minor'], 12500);
  });

  test('rejects blank description, blank category, and non-positive amount', () async {
    final invalidInputs = <Map<String, Object>>[
      {'description': ' ', 'category': 'مرافق', 'amount': 100},
      {'description': 'مصروف', 'category': ' ', 'amount': 100},
      {'description': 'مصروف', 'category': 'مرافق', 'amount': 0},
      {'description': 'مصروف', 'category': 'مرافق', 'amount': -1},
    ];

    for (final input in invalidInputs) {
      await expectLater(
        expenses.add(
          description: input['description']! as String,
          category: input['category']! as String,
          amountMinor: input['amount']! as int,
        ),
        throwsA(isA<AppException>()),
      );
    }
    expect(await db.query('expenses'), isEmpty);
  });
}
