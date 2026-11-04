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

  test('records expense in audit trail and cash outflow atomically', () async {
    final id = await expenses.add(
      description: 'إيجار المحل',
      category: 'إيجار',
      amountMinor: 25000,
    );
    final cash = (await db.query('cash_transactions')).single;
    expect(cash['direction'], 'out');
    expect(cash['category'], 'expense');
    expect(cash['amount_minor'], 25000);
    expect(cash['source_type'], 'expense');
    expect(cash['source_id'], id);
    final audit = (await db.query('audit_events')).single;
    expect(audit['action'], 'expense_recorded');
    expect(audit['entity_id'], id);
    expect(audit['amount_minor'], 25000);
  });

  test('rolls back expense and audit when cash journal write fails', () async {
    await db.execute('''
      CREATE TRIGGER reject_cash_expense
      BEFORE INSERT ON cash_transactions
      WHEN NEW.category = 'expense'
      BEGIN
        SELECT RAISE(ABORT, 'forced cash journal failure');
      END
    ''');
    await expectLater(
      expenses.add(
        description: 'مصروف يجب التراجع عنه',
        category: 'تشغيل',
        amountMinor: 1000,
      ),
      throwsA(anything),
    );
    expect(await db.query('expenses'), isEmpty);
    expect(await db.query('audit_events'), isEmpty);
    expect(await db.query('cash_transactions'), isEmpty);
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
