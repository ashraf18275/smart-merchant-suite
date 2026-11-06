import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/expense_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

void main() {
  late Database database;
  late ExpenseRepository expenses;
  late CashbookRepository cashbook;
  late int branchId;
  late int drawerId;
  late int sessionId;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, _businessId);
    expenses = ExpenseRepository(database);
    cashbook = CashbookRepository(database);
    branchId = (await database.query(
      'branches',
      columns: ['id'],
      limit: 1,
    )).single['id']! as int;
    drawerId = (await cashbook.ensureDrawer(branchId: branchId))['id']! as int;
    sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 1000,
      note: 'افتتاح اختباري',
    );
  });

  tearDown(() async => database.close());

  test('cash expense and Outbox event are committed in the same transaction', () async {
    final expenseId = await expenses.add(
      description: 'فاتورة كهرباء',
      category: 'مرافق',
      amountMinor: 500,
      branchId: branchId,
    );

    final events = await database.query(
      'sync_outbox',
      orderBy: 'rowid ASC',
    );
    expect(events, hasLength(2));
    final openEvent = events.first;
    final expenseEvent = events.last;
    expect(openEvent['entity_type'], 'cash_session');
    expect(openEvent['action'], 'create');
    expect(expenseEvent['entity_type'], 'expense');
    expect(expenseEvent['action'], 'create');
    expect(expenseEvent['local_entity_id'], expenseId.toString());
    expect(expenseEvent['depends_on_event_id'], openEvent['event_id']);
    expect(expenseEvent['payload_json'], contains('"local_branch_id":$branchId'));
    expect(
      expenseEvent['payload_json'],
      contains('"local_cash_session_id":$sessionId'),
    );
    expect(expenseEvent['payload_json'], contains('"payment_method":"cash"'));

    final cash = (await database.query(
      'cash_transactions',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: ['expense', expenseId],
    )).single;
    expect(cash['cash_session_id'], sessionId);
    expect(cash['cash_drawer_id'], drawerId);
  });

  test('closing a session depends on its pending expense events', () async {
    final expenseId = await expenses.add(
      description: 'مصروف صيانة',
      category: 'صيانة',
      amountMinor: 250,
      branchId: branchId,
    );
    final events = await database.query(
      'sync_outbox',
      orderBy: 'rowid ASC',
    );
    final openEventId = events.first['event_id']! as String;
    final expenseEventId = events.last['event_id']! as String;

    await cashbook.closeSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      sessionId: sessionId,
      countedBalanceMinor: 750,
    );

    final closeEvent = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND action = ?',
      whereArgs: ['cash_session', 'update'],
    )).single;
    final dependencies = await database.query(
      'sync_outbox_dependencies',
      columns: ['depends_on_event_id'],
      where: 'event_id = ?',
      whereArgs: [closeEvent['event_id']],
    );
    expect(
      dependencies.map((row) => row['depends_on_event_id']).toSet(),
      {openEventId, expenseEventId},
    );
    expect(closeEvent['local_entity_id'], sessionId.toString());
    expect(expenseEventId, isNotEmpty);
    expect(expenseId, greaterThan(0));
  });

  test('non-cash expense queues without a cash session dependency', () async {
    final expenseId = await expenses.add(
      description: 'اشتراك إلكتروني',
      category: 'خدمات',
      amountMinor: 300,
      branchId: branchId,
      paymentMethod: PaymentMethod.wallet,
    );
    final event = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['expense', expenseId.toString()],
    )).single;
    expect(event['depends_on_event_id'], isNull);
    expect(event['payload_json'], contains('"payment_method":"wallet"'));
    expect(event['payload_json'], isNot(contains('local_cash_session_id')));
    expect(await database.query('cash_transactions'), isEmpty);
  });

  test('Outbox failure rolls back expense, audit, payment and cash journal', () async {
    await database.execute('''
      CREATE TRIGGER reject_expense_outbox
      BEFORE INSERT ON sync_outbox
      WHEN NEW.entity_type = 'expense'
      BEGIN
        SELECT RAISE(ABORT, 'forced expense outbox failure');
      END
    ''');

    await expectLater(
      expenses.add(
        description: 'مصروف يجب ألا يحفظ',
        category: 'تشغيل',
        amountMinor: 700,
        branchId: branchId,
      ),
      throwsA(anything),
    );

    expect(await database.query('expenses'), isEmpty);
    expect(
      await database.query(
        'audit_events',
        where: 'entity_type = ?',
        whereArgs: ['expense'],
      ),
      isEmpty,
    );
    expect(await database.query('payment_records'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
    expect(
      await database.query('sync_outbox', where: 'entity_type = ?', whereArgs: ['expense']),
      isEmpty,
    );
  });
}
