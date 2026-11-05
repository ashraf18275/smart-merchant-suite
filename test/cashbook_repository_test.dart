import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/audit_cash_writer.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late CashbookRepository cashbook;
  late int branchId;
  late int drawerId;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    cashbook = CashbookRepository(db);
    branchId = (await cashbook.branches()).first.id;
    drawerId = (await cashbook.ensureDrawer(branchId: branchId))['id']! as int;
  });
  tearDown(() async => db.close());

  test('calculates cash inflows, outflows and net balance from the journal', () async {
    final stamp = DateTime.utc(2026, 11, 4).toIso8601String();
    await db.insert('cash_transactions', {
      'direction': 'in',
      'category': 'sale_receipt',
      'amount_minor': 15000,
      'source_type': 'sale',
      'source_id': 1, 'branch_id': branchId, 'cash_drawer_id': drawerId,
      'created_at': stamp,
    });
    await db.insert('cash_transactions', {
      'direction': 'out',
      'category': 'expense',
      'amount_minor': 2500,
      'source_type': 'expense',
      'source_id': 1, 'branch_id': branchId, 'cash_drawer_id': drawerId,
      'created_at': stamp,
    });
    expect(await cashbook.totals(branchId: branchId, cashDrawerId: drawerId), {
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
        branchId: branchId,
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
        branchId: branchId,
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
        branchId: branchId,
        createdAt: stamp,
      );
    });

    final totals = await cashbook.totals(branchId: branchId, cashDrawerId: drawerId);
    expect(totals, {'incoming': 8000, 'outgoing': 0, 'balance': 8000});
    final payments = await cashbook.payments(branchId: branchId);
    expect(payments, hasLength(3));
    expect(payments.map((row) => row['payment_method']).toSet(),
      {'cash', 'card', 'bank_transfer'});
    expect(await cashbook.movements(branchId: branchId, cashDrawerId: drawerId), hasLength(1));
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
    expect(await cashbook.payments(branchId: branchId), isEmpty);
    expect(await cashbook.movements(branchId: branchId, cashDrawerId: drawerId), isEmpty);
  });

  test('opens and closes a cash session with a reconciled physical count', () async {
    final sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 10000,
      note: 'فكة بداية الوردية',
    );
    await expectLater(
      cashbook.openSession(branchId: branchId, cashDrawerId: drawerId, openingBalanceMinor: 5000),
      throwsStateError,
    );

    final stamp = DateTime.utc(2026, 11, 4).toIso8601String();
    await db.transaction((txn) async {
      await writeCashMovement(
        txn,
        direction: 'in',
        category: 'sale_receipt',
        amountMinor: 5000,
        sourceType: 'sale',
        sourceId: 20,
        cashSessionId: sessionId,
        branchId: branchId,
        cashDrawerId: drawerId,
        createdAt: stamp,
      );
      await writeCashMovement(
        txn,
        direction: 'out',
        category: 'expense',
        amountMinor: 2000,
        sourceType: 'expense',
        sourceId: 20,
        cashSessionId: sessionId,
        createdAt: stamp,
      );
      await writeCashMovement(
        txn,
        direction: 'in',
        category: 'sale_receipt',
        amountMinor: 7000,
        sourceType: 'sale',
        sourceId: 21,
        paymentMethod: PaymentMethod.card,
        createdAt: stamp,
      );
    });

    final active = await cashbook.currentSession(branchId: branchId, cashDrawerId: drawerId);
    expect(active!['id'], sessionId);
    expect(active['opening_balance_minor'], 10000);
    expect(active['live_expected_balance_minor'], 13000);
    final result = await cashbook.closeSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      sessionId: sessionId,
      countedBalanceMinor: 12800,
      note: 'عجز 2 جنيه بعد العد',
    );
    expect(result, {
      'session_id': sessionId,
      'opening_balance': 10000,
      'incoming': 5000,
      'outgoing': 2000,
      'expected': 13000,
      'counted': 12800,
      'difference': -200,
    });
    expect(await cashbook.currentSession(branchId: branchId, cashDrawerId: drawerId), isNull);
    final history = await cashbook.sessionHistory(branchId: branchId, cashDrawerId: drawerId);
    expect(history, hasLength(1));
    expect(history.single['status'], 'closed');
    expect(history.single['difference_minor'], -200);
    final sessionMovements = await db.query(
      'cash_transactions',
      where: 'cash_session_id = ?',
      whereArgs: [sessionId],
    );
    expect(sessionMovements, hasLength(2));
    expect(await cashbook.totals(branchId: branchId, cashDrawerId: drawerId), {
      'incoming': 5000,
      'outgoing': 2000,
      'balance': 3000,
    });
  });

  test('allows independent open shifts on two device drawers in one branch', () async {
    final otherDrawerId = await db.insert('cash_drawers', {
      'branch_id': branchId,
      'device_id': 'another-device-id',
      'label': 'جهاز آخر',
      'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final firstSession = await cashbook.openSession(
      branchId: branchId, cashDrawerId: drawerId, openingBalanceMinor: 1000);
    final secondSession = await cashbook.openSession(
      branchId: branchId, cashDrawerId: otherDrawerId, openingBalanceMinor: 2000);

    expect((await cashbook.currentSession(
      branchId: branchId, cashDrawerId: drawerId))!['id'], firstSession);
    expect((await cashbook.currentSession(
      branchId: branchId, cashDrawerId: otherDrawerId))!['id'], secondSession);

    await cashbook.closeSession(
      branchId: branchId, cashDrawerId: drawerId,
      sessionId: firstSession, countedBalanceMinor: 1000);

    expect(await cashbook.currentSession(
      branchId: branchId, cashDrawerId: drawerId), isNull);
    expect((await cashbook.currentSession(
      branchId: branchId, cashDrawerId: otherDrawerId))!['id'], secondSession);
  });

  test('rejects closing a missing session and negative physical counts', () async {
    await expectLater(
      cashbook.closeSession(branchId: branchId, cashDrawerId: drawerId, sessionId: -1, countedBalanceMinor: 0),
      throwsStateError,
    );
    await expectLater(
      cashbook.openSession(branchId: branchId, cashDrawerId: drawerId, openingBalanceMinor: -1),
      throwsArgumentError,
    );
    await cashbook.openSession(branchId: branchId, cashDrawerId: drawerId, openingBalanceMinor: 0);
    await expectLater(
      cashbook.closeSession(branchId: branchId, cashDrawerId: drawerId, sessionId: (await cashbook.currentSession(branchId: branchId, cashDrawerId: drawerId))!['id']! as int, countedBalanceMinor: -1),
      throwsArgumentError,
    );
    expect(await cashbook.currentSession(branchId: branchId, cashDrawerId: drawerId), isNotNull);
  });

  test('lists latest cash movements and audit events first', () async {
    final older = DateTime.utc(2026, 11, 1).toIso8601String();
    final newer = DateTime.utc(2026, 11, 4).toIso8601String();
    await db.insert('cash_transactions', {
      'direction': 'in', 'category': 'sale_receipt', 'amount_minor': 100,
      'source_type': 'sale', 'source_id': 1, 'branch_id': branchId, 'cash_drawer_id': drawerId, 'created_at': older,
    });
    await db.insert('cash_transactions', {
      'direction': 'out', 'category': 'expense', 'amount_minor': 50,
      'source_type': 'expense', 'source_id': 1, 'branch_id': branchId, 'cash_drawer_id': drawerId, 'created_at': newer,
    });
    await db.insert('audit_events', {
      'action': 'sale_created', 'entity_type': 'sale', 'entity_id': 1,
      'created_at': older,
    });
    await db.insert('audit_events', {
      'action': 'expense_recorded', 'entity_type': 'expense', 'entity_id': 1,
      'created_at': newer,
    });
    expect((await cashbook.movements(branchId: branchId, cashDrawerId: drawerId)).first['category'], 'expense');
    expect((await cashbook.auditEvents()).first['action'], 'expense_recorded');
  });
}
