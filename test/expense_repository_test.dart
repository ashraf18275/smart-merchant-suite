import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/expense_repository.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ExpenseRepository expenses;
  late int branchId;
  late int drawerId;
  late int sessionId;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    expenses = ExpenseRepository(db);
    branchId = (await db.query('branches', columns: ['id'], limit: 1)).single['id']! as int;
    final cashbook = CashbookRepository(db);
    drawerId = (await cashbook.ensureDrawer(branchId: branchId))['id']! as int;
    sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 0,
    );
  });
  tearDown(() async => db.close());

  test('requires an open drawer session before recording a cash expense', () async {
    await CashbookRepository(db).closeSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      sessionId: sessionId,
      countedBalanceMinor: 0,
    );
    await expectLater(
      expenses.add(
        description: 'مصروف نقدي',
        category: 'تشغيل',
        amountMinor: 100,
        branchId: branchId,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('expenses'), isEmpty);
    expect(await db.query('payment_records'), isEmpty);
  });

  test('records a valid expense with trimmed text', () async {
    final id = await expenses.add(
      description: '  فاتورة كهرباء  ',
      category: '  مرافق  ',
      amountMinor: 12500,
      branchId: branchId,
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
      branchId: branchId,
    );
    final cash = (await db.query('cash_transactions')).single;
    expect(cash['direction'], 'out');
    expect(cash['category'], 'expense');
    expect(cash['amount_minor'], 25000);
    expect(cash['source_type'], 'expense');
    expect(cash['source_id'], id);
    final audit = (await db.query(
      'audit_events',
      where: 'action = ?',
      whereArgs: ['expense_recorded'],
    )).single;
    expect(audit['action'], 'expense_recorded');
    expect(audit['entity_id'], id);
    expect(audit['amount_minor'], 25000);
  });

  test('records wallet expense payment without cash outflow', () async {
    final id = await expenses.add(
      description: 'شراء إلكتروني',
      category: 'تشغيل',
      amountMinor: 2500,
      branchId: branchId,
      paymentMethod: PaymentMethod.wallet,
    );
    final payment = (await db.query('payment_records')).single;
    expect(payment['source_type'], 'expense');
    expect(payment['source_id'], id);
    expect(payment['payment_method'], 'wallet');
    expect(payment['direction'], 'out');
    expect(await db.query('cash_transactions'), isEmpty);
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
        branchId: branchId,
      ),
      throwsA(anything),
    );
    expect(await db.query('expenses'), isEmpty);
    expect(
      await db.query('audit_events', where: 'action = ?', whereArgs: ['expense_recorded']),
      isEmpty,
    );
    expect(await db.query('cash_transactions'), isEmpty);
  });

  test('isolates expense rows and profit summary by branch', () async {
    final stamp = DateTime.now().toUtc().toIso8601String();
    final secondBranchId = await db.insert('branches', {
      'name': 'فرع الاختبار',
      'is_active': 1,
      'created_at': stamp,
    });
    final secondWarehouseId = await db.insert('warehouses', {
      'branch_id': secondBranchId,
      'name': 'مخزن الاختبار',
      'is_active': 1,
      'created_at': stamp,
    });
    final firstWarehouseId = (await db.query('warehouses',
      columns: ['id'], where: 'branch_id = ?', whereArgs: [branchId],
      limit: 1)).single['id']! as int;

    await expenses.add(description: 'مصروف الفرع الأول', category: 'تشغيل',
      amountMinor: 1200, branchId: branchId,
      paymentMethod: PaymentMethod.wallet);
    await expenses.add(description: 'مصروف الفرع الثاني', category: 'تشغيل',
      amountMinor: 3400, branchId: secondBranchId,
      paymentMethod: PaymentMethod.wallet);

    await db.insert('sales', {
      'total_minor': 8000, 'paid_minor': 8000,
      'warehouse_id': firstWarehouseId, 'created_at': stamp,
    });
    await db.insert('sales', {
      'total_minor': 15000, 'paid_minor': 15000,
      'warehouse_id': secondWarehouseId, 'created_at': stamp,
    });
    // Historical sales without a warehouse remain outside branch reports.
    await db.insert('sales', {
      'total_minor': 99000, 'paid_minor': 99000, 'created_at': stamp,
    });

    final firstRows = await expenses.all(branchId: branchId);
    final secondRows = await expenses.all(branchId: secondBranchId);
    final firstSummary = await expenses.summary(branchId: branchId);
    final secondSummary = await expenses.summary(branchId: secondBranchId);

    expect(firstRows.map((row) => row.description), ['مصروف الفرع الأول']);
    expect(secondRows.map((row) => row.description), ['مصروف الفرع الثاني']);
    expect(firstSummary.salesMinor, 8000);
    expect(secondSummary.salesMinor, 15000);
    expect(firstSummary.expensesMinor, 1200);
    expect(secondSummary.expensesMinor, 3400);
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
          branchId: branchId,
        ),
        throwsA(isA<AppException>()),
      );
    }
    expect(await db.query('expenses'), isEmpty);
  });
}
