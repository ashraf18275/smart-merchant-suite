import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_cash_session_write_repository.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/sync_outbox_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _branchCloudId = 'af8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _sessionCloudId = 'bf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

class _RpcCall {
  const _RpcCall(this.function, this.parameters);
  final String function;
  final Map<String, dynamic> parameters;
}

class _FakeRpc implements CloudCashSessionRpcClient {
  final calls = <_RpcCall>[];
  Object? openResult = _sessionCloudId;
  Object? closeResult = {'session_id': _sessionCloudId};

  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async {
    calls.add(_RpcCall(function, Map<String, dynamic>.from(parameters)));
    return function == 'open_cloud_cash_session' ? openResult : closeResult;
  }
}

void main() {
  late Database database;
  late CashbookRepository cashbook;
  late SyncOutboxRepository outbox;
  late _FakeRpc rpc;
  late CloudCashSessionWriteRepository repository;
  late int branchId;
  late int drawerId;
  late int sessionId;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, _businessId);
    cashbook = CashbookRepository(database);
    outbox = SyncOutboxRepository(database);
    branchId = (await cashbook.branches()).single.id;
    drawerId = (await cashbook.ensureDrawer(branchId: branchId))['id']! as int;
    await outbox.upsertEntityMapping(
      businessId: _businessId,
      entityType: 'branch',
      localEntityId: branchId.toString(),
      remoteEntityId: _branchCloudId,
    );
    rpc = _FakeRpc();
    repository = CloudCashSessionWriteRepository(
      database: database,
      rpc: rpc,
    );
  });

  tearDown(() async => database.close());

  test('opens and closes a mapped device session through idempotent RPC contracts', () async {
    sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 2500,
      note: 'بداية الوردية',
    );
    final openEvent = (await outbox.claimPendingBatch(
      businessId: _businessId,
    )).single;

    final remoteId = await repository.openFromEvent(openEvent);
    expect(remoteId, _sessionCloudId);
    expect(rpc.calls.single.function, 'open_cloud_cash_session');
    expect(rpc.calls.single.parameters, {
      'p_business_id': _businessId,
      'p_branch_id': _branchCloudId,
      'p_register_key': (await database.query(
        'cash_drawers',
        columns: ['device_id'],
        where: 'id = ?',
        whereArgs: [drawerId],
      )).single['device_id'],
      'p_opening_balance_minor': 2500,
      'p_note': 'بداية الوردية',
      'p_operation_id': openEvent.operationId,
    });
    await outbox.markSynced(openEvent.eventId, remoteEntityId: remoteId);

    await cashbook.closeSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      sessionId: sessionId,
      countedBalanceMinor: 2500,
      note: 'إغلاق',
    );
    final closeEvent = (await outbox.claimPendingBatch(
      businessId: _businessId,
    )).single;
    expect(closeEvent.action, 'update');

    final closedRemoteId = await repository.closeFromEvent(closeEvent);
    expect(closedRemoteId, _sessionCloudId);
    expect(rpc.calls.last.function, 'close_cloud_cash_session');
    expect(rpc.calls.last.parameters, {
      'p_business_id': _businessId,
      'p_cash_session_id': _sessionCloudId,
      'p_counted_balance_minor': 2500,
      'p_note': 'إغلاق',
      'p_operation_id': closeEvent.operationId,
    });
  });

  test('does not call open RPC without an explicit branch mapping', () async {
    await database.delete('sync_entity_map');
    sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 0,
    );
    final event = (await outbox.claimPendingBatch(
      businessId: _businessId,
    )).single;

    await expectLater(repository.openFromEvent(event), throwsStateError);
    expect(rpc.calls, isEmpty);
  });

  test('refuses to close a session while its open dependency is not synced', () async {
    sessionId = await cashbook.openSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      openingBalanceMinor: 100,
    );
    final openEvent = (await database.query(
      'sync_outbox',
      where: 'entity_type = ?',
      whereArgs: ['cash_session'],
    )).single;
    await cashbook.closeSession(
      branchId: branchId,
      cashDrawerId: drawerId,
      sessionId: sessionId,
      countedBalanceMinor: 100,
    );
    final closeRow = (await database.query(
      'sync_outbox',
      where: "entity_type = ? AND action = 'update'",
      whereArgs: ['cash_session'],
    )).single;
    final closeEvent = SyncOutboxEvent.fromRow(closeRow);

    expect(closeEvent.dependsOnEventId, openEvent['event_id']);
    await expectLater(
      repository.closeFromEvent(closeEvent),
      throwsStateError,
    );
    expect(rpc.calls, isEmpty);
  });
}
