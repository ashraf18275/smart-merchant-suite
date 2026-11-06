import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_cash_session_write_repository.dart';
import 'package:smart_merchant_suite/cloud/cloud_expense_write_repository.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/expense_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/sync_outbox_repository.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _branchCloudId = 'af8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _sessionCloudId = 'bf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _expenseCloudId = 'cf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

class _RpcCall {
  const _RpcCall(this.function, this.parameters);
  final String function;
  final Map<String, dynamic> parameters;
}

class _FakeCashRpc implements CloudCashSessionRpcClient {
  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async =>
      _sessionCloudId;
}

class _FakeExpenseRpc implements CloudExpenseRpcClient {
  Object? result = _expenseCloudId;
  final calls = <_RpcCall>[];

  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async {
    calls.add(_RpcCall(function, Map<String, dynamic>.from(parameters)));
    return result;
  }
}

void main() {
  late Database database;
  late CashbookRepository cashbook;
  late ExpenseRepository expenses;
  late SyncOutboxRepository outbox;
  late CloudCashSessionWriteRepository cashSessionWriter;
  late CloudExpenseWriteRepository expenseWriter;
  late _FakeExpenseRpc expenseRpc;
  late int branchId;
  late int drawerId;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, _businessId);
    cashbook = CashbookRepository(database);
    expenses = ExpenseRepository(database);
    outbox = SyncOutboxRepository(database);
    branchId = (await cashbook.branches()).single.id;
    drawerId = (await cashbook.ensureDrawer(branchId: branchId))['id']! as int;
    await outbox.upsertEntityMapping(
      businessId: _businessId,
      entityType: 'branch',
      localEntityId: branchId.toString(),
      remoteEntityId: _branchCloudId,
    );
    cashSessionWriter = CloudCashSessionWriteRepository(
      database: database,
      rpc: _FakeCashRpc(),
    );
    expenseRpc = _FakeExpenseRpc();
    expenseWriter = CloudExpenseWriteRepository(
      database: database,
      rpc: expenseRpc,
    );
  });

  tearDown(() async => database.close());

  Future<int> openAndSyncSession() async {
    final sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 1000,
    );
    final openEvent = (await outbox.claimPendingBatch(
      businessId: _businessId,
    )).single;
    final remoteId = await cashSessionWriter.openFromEvent(openEvent);
    await outbox.markSynced(openEvent.eventId, remoteEntityId: remoteId);
    return sessionId;
  }

  test('maps a cash expense to the branch and synced cloud cash session', () async {
    final sessionId = await openAndSyncSession();
    final expenseId = await expenses.add(
      description: 'فاتورة كهرباء',
      category: 'مرافق',
      amountMinor: 1250,
      branchId: branchId,
    );
    final event = (await outbox.claimPendingBatch(
      businessId: _businessId,
    )).single;

    final remoteId = await expenseWriter.createFromEvent(event);
    expect(remoteId, _expenseCloudId);
    expect(expenseRpc.calls, hasLength(1));
    expect(expenseRpc.calls.single.function, 'create_cloud_expense');
    expect(expenseRpc.calls.single.parameters, {
      'p_business_id': _businessId,
      'p_branch_id': _branchCloudId,
      'p_description': 'فاتورة كهرباء',
      'p_category': 'مرافق',
      'p_amount_minor': 1250,
      'p_payment_method': PaymentMethod.cash,
      'p_cash_session_id': _sessionCloudId,
      'p_operation_id': event.operationId,
    });
    expect(event.localEntityId, expenseId.toString());
    expect(await outbox.remoteIdFor(
      businessId: _businessId,
      entityType: 'expense',
      localEntityId: expenseId.toString(),
    ), _expenseCloudId);
    expect(sessionId, greaterThan(0));
  });

  test('maps a non-cash expense without a cash session', () async {
    final expenseId = await expenses.add(
      description: 'اشتراك إلكتروني',
      category: 'خدمات',
      amountMinor: 300,
      branchId: branchId,
      paymentMethod: PaymentMethod.wallet,
    );
    final eventRow = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['expense', expenseId.toString()],
    )).single;
    final event = SyncOutboxEvent.fromRow(eventRow);

    final remoteId = await expenseWriter.createFromEvent(event);
    expect(remoteId, _expenseCloudId);
    expect(expenseRpc.calls.single.parameters['p_cash_session_id'], isNull);
    expect(
      expenseRpc.calls.single.parameters['p_payment_method'],
      PaymentMethod.wallet,
    );
  });

  test('refuses cash expense before the cash session open event is synced', () async {
    await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 100,
    );
    final expenseId = await expenses.add(
      description: 'مصروف نقدي',
      category: 'تشغيل',
      amountMinor: 100,
      branchId: branchId,
    );
    final eventRow = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['expense', expenseId.toString()],
    )).single;
    final event = SyncOutboxEvent.fromRow(eventRow);

    await expectLater(expenseWriter.createFromEvent(event), throwsStateError);
    expect(expenseRpc.calls, isEmpty);
  });

  test('refuses to send an expense when branch mapping is missing', () async {
    final expenseId = await expenses.add(
      description: 'مصروف محفظة',
      category: 'تشغيل',
      amountMinor: 100,
      branchId: branchId,
      paymentMethod: PaymentMethod.wallet,
    );
    await database.delete('sync_entity_map');
    final eventRow = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['expense', expenseId.toString()],
    )).single;

    await expectLater(
      expenseWriter.createFromEvent(SyncOutboxEvent.fromRow(eventRow)),
      throwsStateError,
    );
    expect(expenseRpc.calls, isEmpty);
  });

  test('rejects a changed local expense snapshot before RPC', () async {
    final expenseId = await expenses.add(
      description: 'مصروف محفظة',
      category: 'تشغيل',
      amountMinor: 100,
      branchId: branchId,
      paymentMethod: PaymentMethod.wallet,
    );
    await database.update(
      'expenses',
      {'amount_minor': 101},
      where: 'id = ?',
      whereArgs: [expenseId],
    );
    final eventRow = (await database.query(
      'sync_outbox',
      where: 'entity_type = ? AND local_entity_id = ?',
      whereArgs: ['expense', expenseId.toString()],
    )).single;

    await expectLater(
      expenseWriter.createFromEvent(SyncOutboxEvent.fromRow(eventRow)),
      throwsStateError,
    );
    expect(expenseRpc.calls, isEmpty);
  });
}
