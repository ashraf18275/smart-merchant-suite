import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/sync_outbox_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late SyncOutboxRepository outbox;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    outbox = SyncOutboxRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('persists one stable device identity', () async {
    final first = await outbox.ensureDeviceId();
    final second = await outbox.ensureDeviceId();

    expect(first, isNotEmpty);
    expect(second, first);
    expect(first, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('enqueues in the caller transaction and binds only explicitly', () async {
    final eventId = await database.transaction((txn) {
      return outbox.enqueue(
        executor: txn,
        entityType: 'product',
        localEntityId: '42',
        action: 'create',
        payload: {'name': 'قلم', 'price_minor': 1250},
      );
    });

    expect(await outbox.pendingCount(), 1);
    expect(await outbox.claimPendingBatch(), isEmpty);

    expect(await outbox.assignUnboundEventsToBusiness('business-uuid'), 1);
    final claimed = await outbox.claimPendingBatch();

    expect(claimed, hasLength(1));
    expect(claimed.single.eventId, eventId);
    expect(claimed.single.businessId, 'business-uuid');
    expect(claimed.single.entityType, 'product');
    expect(claimed.single.localEntityId, '42');
    expect(claimed.single.payload['name'], 'قلم');
    expect(claimed.single.attempts, 1);
    expect(claimed.single.status, 'processing');
  });

  test('retries failed events with an incremented attempt count', () async {
    await outbox.enqueue(
      businessId: 'business-uuid',
      entityType: 'expense',
      localEntityId: '9',
      action: 'create',
      payload: {'amount_minor': 300},
    );

    final first = (await outbox.claimPendingBatch()).single;
    await outbox.markFailed(first.eventId, StateError('temporary network issue'));

    final retry = (await outbox.claimPendingBatch()).single;
    expect(retry.eventId, first.eventId);
    expect(retry.attempts, 2);
    expect(retry.status, 'processing');

    await outbox.markSynced(retry.eventId, remoteEntityId: 'remote-expense-id');
    expect(await outbox.pendingCount(businessId: 'business-uuid'), 0);
    expect(
      await outbox.remoteIdFor(
        businessId: 'business-uuid',
        entityType: 'expense',
        localEntityId: '9',
      ),
      isNull,
    );
  });

  test('stores conflict snapshots and blocks automatic retry', () async {
    await outbox.enqueue(
      businessId: 'business-uuid',
      entityType: 'product',
      localEntityId: '7',
      action: 'update',
      payload: {'price_minor': 2000},
    );
    final event = (await outbox.claimPendingBatch()).single;
    await outbox.recordConflict(
      eventId: event.eventId,
      conflictType: 'remote_record_changed',
      remotePayload: {'price_minor': 2200},
    );

    expect(await outbox.claimPendingBatch(), isEmpty);
    final conflicts = await database.query('sync_conflicts');
    expect(conflicts, hasLength(1));
    expect(conflicts.single['conflict_type'], 'remote_record_changed');
    expect(conflicts.single['business_id'], 'business-uuid');
  });

  test('maps local entities to one cloud identity per business', () async {
    await outbox.upsertEntityMapping(
      businessId: 'business-a',
      entityType: 'product',
      localEntityId: '1',
      remoteEntityId: 'remote-a',
    );
    await outbox.upsertEntityMapping(
      businessId: 'business-b',
      entityType: 'product',
      localEntityId: '1',
      remoteEntityId: 'remote-b',
    );

    expect(
      await outbox.remoteIdFor(
        businessId: 'business-a',
        entityType: 'product',
        localEntityId: '1',
      ),
      'remote-a',
    );
    expect(
      await outbox.localIdFor(
        businessId: 'business-b',
        entityType: 'product',
        remoteEntityId: 'remote-b',
      ),
      '1',
    );

    await expectLater(
      outbox.upsertEntityMapping(
        businessId: 'business-a',
        entityType: 'product',
        localEntityId: '1',
        remoteEntityId: 'different-remote',
      ),
      throwsStateError,
    );
  });

  test('stores a separate incremental cursor per business and scope', () async {
    await outbox.saveCursor(
      businessId: 'business-a',
      scope: 'products',
      cursor: '2026-11-04T12:00:00Z',
    );
    await outbox.saveCursor(
      businessId: 'business-b',
      scope: 'products',
      cursor: '2026-11-04T13:00:00Z',
    );

    expect(
      await outbox.cursorFor(businessId: 'business-a', scope: 'products'),
      '2026-11-04T12:00:00Z',
    );
    expect(
      await outbox.cursorFor(businessId: 'business-b', scope: 'products'),
      '2026-11-04T13:00:00Z',
    );
  });
}
