import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/audit_cash_writer.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late CashbookRepository cashbook;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    cashbook = CashbookRepository(db);
  });
  tearDown(() async => db.close());

  test('calculates cash inflows, outflows and net balance from the journal', () async {
    final stamp = DateTime.utc(2026, 11, 4).toIso8601String();
    await db.insert('cash_transactions', {
      'direction': 'in',
      'category': 'sale_receipt',
      'amount_minor': 15000,
      'source_type': 'sale',
      'source_id': 1,
      'created_at': stamp,
    });
    await db.insert('cash_transactions', {
      'direction': 'out',
      'category': 'expense',
      'amount_minor': 2500,
      'source_type': 'expense',
      'source_id': 1,
      'created_at': stamp,
    });
    expect(await cashbook.totals(), {
      'incoming': 15000,
      'outgoing': 2500,
      'balance': 12500,
    });
  });

  test('non-cash settlements are recorded but never inflate drawer cash', () async {
    final stamp = DateTime.utc(2026, 11, 4).toIso8601String();
    await db.transaction((txn) async {
      await writeCashMovement(
        txn,
        direction: 'in',
        category: 'sale_receipt',
        amountMinor: 8000,
        sourceType: 'sale',
        sourceId: 10,
        paymentMethod: PaymentMethod.cash,
        createdAt: stamp,
      );
      await writeCashMovement(
        txn,
        direction: 'in',
        category: 'sale_receipt',
        amountMinor: 12000,
        sourceType: 'sale',
        sourceId: 11,
        paymentMethod: PaymentMethod.card,
        createdAt: stamp,
      );
      await writeCashMovement(
        txn,
        direction: 'out',
        category: 'purchase_payment',
        amountMinor: 5000,
        sourceType: 'purchase',
        sourceId: 12,
        paymentMethod: PaymentMethod.bankTransfer,
        createdAt: stamp,
      );
    });

    final totals = await cashbook.totals();
    expect(totals, {'incoming': 8000, 'outgoing': 0, 'balance': 8000});
    final payments = await cashbook.payments();
    expect(payments, hasLength(3));
    expect(payments.map((row) => row['payment_method']).toSet(),
      {'cash', 'card', 'bank_transfer'});
    expect(await cashbook.movements(), hasLength(1));
  });

  test('rejects an unsupported settlement method atomically', () async {
    await expectLater(
      db.transaction((txn) => writeCashMovement(
        txn,
        direction: 'in',
        category: 'sale_receipt',
        amountMinor: 100,
        sourceType: 'sale',
        sourceId: 99,
        paymentMethod: 'crypto',
      )),
      throwsArgumentError,
    );
    expect(await cashbook.payments(), isEmpty);
    expect(await cashbook.movements(), isEmpty);
  });

  test('lists latest cash movements and audit events first', () async {
    final older = DateTime.utc(2026, 11, 1).toIso8601String();
    final newer = DateTime.utc(2026, 11, 4).toIso8601String();
    await db.insert('cash_transactions', {
      'direction': 'in', 'category': 'sale_receipt', 'amount_minor': 100,
      'source_type': 'sale', 'source_id': 1, 'created_at': older,
    });
    await db.insert('cash_transactions', {
      'direction': 'out', 'category': 'expense', 'amount_minor': 50,
      'source_type': 'expense', 'source_id': 1, 'created_at': newer,
    });
    await db.insert('audit_events', {
      'action': 'sale_created', 'entity_type': 'sale', 'entity_id': 1,
      'created_at': older,
    });
    await db.insert('audit_events', {
      'action': 'expense_recorded', 'entity_type': 'expense', 'entity_id': 1,
      'created_at': newer,
    });
    expect((await cashbook.movements()).first['category'], 'expense');
    expect((await cashbook.auditEvents()).first['action'], 'expense_recorded');
  });
}
