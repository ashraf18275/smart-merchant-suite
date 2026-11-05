import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
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
    await ensureBusinessDatabaseIdentity(
      database,
      '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
    );
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

  test('enqueues atomically and binds one event only after explicit confirmation', () async {
    final firstEventId = await database.transaction((txn) {
      return outbox.enqueue(
        executor: txn,
        entityType: 'product',
        localEntityId: '42',
        action: 'create',
        payload: {'name': 'قلم', 'price_minor': 1250},
      );
    });
    final secondEventId = await outbox.enqueue(
      entityType: 'expense',
      localEntityId: '9',
      action: 'create',
      payload: {'amount_minor': 300},
    );

    expect(await outbox.pendingCount(), 2);
    expect(await outbox.claimPendingBatch(businessId: 'business-a'), isEmpty);

    await expectLater(
      outbox.bindEventToBusiness(
        eventId: firstEventId,
        businessId: 'business-a',
        explicitlyConfirmed: false,
      ),
      throwsStateError,
    );

    await outbox.bindEventToBusiness(
      eventId: firstEventId,
      businessId: 'business-a',
      explicitlyConfirmed: true,
    );
    await outbox.bindEventToBusiness(
      eventId: secondEventId,
      businessId: 'business-b',
      explicitlyConfirmed: true,
    );

    final claimed = await outbox.claimPendingBatch(businessId: 'business-a');
    expect(claimed, hasLength(1));
    expect(claimed.single.eventId, firstEventId);
    expect(claimed.single.businessId, 'business-a');
    expect(claimed.single.entityType, 'product');
    expect(claimed.single.localEntityId, '42');
    expect(claimed.single.payload['name'], 'قلم');
    expect(claimed.single.attempts, 1);
    expect(claimed.single.status, 'processing');

    final otherTenant = await outbox.claimPendingBatch(businessId: 'business-b');
    expect(otherTenant, hasLength(1));
    expect(otherTenant.single.eventId, secondEventId);
  });

  test('dependent events are not claimable until their parent is synced', () async {
    final parentId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'product',
      localEntityId: '42',
      action: 'create',
      payload: {'name': 'قلم'},
    );
    final childId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'inventory_movement',
      localEntityId: 'movement-1',
      action: 'adjust',
      payload: {'local_product_id': '42'},
      dependsOnEventId: parentId,
    );

    final firstBatch = await outbox.claimPendingBatch(businessId: 'business-a');
    expect(firstBatch, hasLength(1));
    expect(firstBatch.single.eventId, parentId);

    await outbox.markSynced(parentId, remoteEntityId: 'remote-product-42');
    final secondBatch = await outbox.claimPendingBatch(businessId: 'business-a');
    expect(secondBatch, hasLength(1));
    expect(secondBatch.single.eventId, childId);
    expect(secondBatch.single.dependsOnEventId, parentId);
  });

  test('a sale with multiple product dependencies waits for every parent', () async {
    const tenantId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
    final firstProduct = await outbox.enqueue(
      businessId: tenantId,
      entityType: 'product',
      localEntityId: '101',
      action: 'create',
      payload: {'name': 'منتج أول'},
    );
    final secondProduct = await outbox.enqueue(
      businessId: tenantId,
      entityType: 'product',
      localEntityId: '202',
      action: 'create',
      payload: {'name': 'منتج ثان'},
    );
    final saleId = await outbox.enqueue(
      businessId: tenantId,
      entityType: 'sale',
      localEntityId: '900',
      action: 'create',
      payload: {'items': ['101', '202']},
      dependsOnEventIds: [firstProduct, secondProduct],
    );

    final initial = await outbox.claimPendingBatch(businessId: tenantId);
    expect(initial.map((event) => event.eventId).toSet(),
        {firstProduct, secondProduct});

    await outbox.markSynced(firstProduct);
    final afterFirst = await outbox.claimPendingBatch(businessId: tenantId);
    expect(afterFirst, hasLength(1));
    expect(afterFirst.single.eventId, secondProduct);

    await outbox.markSynced(secondProduct);
    final afterBoth = await outbox.claimPendingBatch(businessId: tenantId);
    expect(afterBoth, hasLength(1));
    expect(afterBoth.single.eventId, saleId);
    expect(afterBoth.single.dependsOnEventId, firstProduct);
  });

  test('latest unfinished event lookup returns one newest parent per local product', () async {
    const tenantId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
    await outbox.enqueue(
      businessId: tenantId,
      entityType: 'product',
      localEntityId: '10',
      action: 'create',
      payload: {'name': 'منتج 10'},
    );
    final latestFor10 = await outbox.enqueue(
      businessId: tenantId,
      entityType: 'product',
      localEntityId: '10',
      action: 'update',
      payload: {'name': 'منتج 10 محدث'},
    );
    final latestFor11 = await outbox.enqueue(
      businessId: tenantId,
      entityType: 'product',
      localEntityId: '11',
      action: 'create',
      payload: {'name': 'منتج 11'},
    );

    final dependencies = await outbox.latestUnfinishedEventIdsForCurrentBusiness(
      executor: database,
      entityType: 'product',
      localEntityIds: ['10', '11', '10'],
    );
    expect(dependencies.toSet(), {latestFor10, latestFor11});
    expect(dependencies, hasLength(2));
  });

  test('a failed parent blocks its dependent event while parent retry remains pending', () async {
    final parentId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'product',
      localEntityId: '43',
      action: 'create',
      payload: {'name': 'مسطرة'},
    );
    final childId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'inventory_movement',
      localEntityId: 'movement-2',
      action: 'adjust',
      payload: {'local_product_id': '43'},
      dependsOnEventId: parentId,
    );

    final parent = (await outbox.claimPendingBatch(businessId: 'business-a')).single;
    await outbox.markFailed(parent.eventId, StateError('temporary failure'));
    final retryBatch = await outbox.claimPendingBatch(businessId: 'business-a');
    expect(retryBatch, hasLength(1));
    expect(retryBatch.single.eventId, parentId);
    expect(retryBatch.any((event) => event.eventId == childId), isFalse);
  });

  test('a conflicted parent remains a dependency anchor for later local events', () async {
    final parentId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'product',
      localEntityId: '45',
      action: 'create',
      payload: {'name': 'ممحاة'},
    );
    final parent = (await outbox.claimPendingBatch(businessId: 'business-a')).single;
    await outbox.recordConflict(
      eventId: parent.eventId,
      conflictType: 'duplicate_sku',
    );

    final childId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'inventory_movement',
      localEntityId: 'movement-5',
      action: 'adjust',
      payload: {'local_product_id': '45'},
      dependsOnEventId: parentId,
    );

    expect(await outbox.claimPendingBatch(businessId: 'business-a'), isEmpty);
    final child = (await database.query(
      'sync_outbox',
      where: 'event_id = ?',
      whereArgs: [childId],
    )).single;
    expect(child['status'], 'pending');
    expect(child['depends_on_event_id'], parentId);
  });

  test('dependency cannot cross tenant boundaries or point to a missing event', () async {
    final parentId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'product',
      localEntityId: '44',
      action: 'create',
      payload: {'name': 'دفتر'},
    );

    await expectLater(
      outbox.enqueue(
        businessId: 'business-b',
        entityType: 'inventory_movement',
        localEntityId: 'movement-3',
        action: 'adjust',
        payload: {'local_product_id': '44'},
        dependsOnEventId: parentId,
      ),
      throwsStateError,
    );
    await expectLater(
      outbox.enqueue(
        businessId: 'business-a',
        entityType: 'inventory_movement',
        localEntityId: 'movement-4',
        action: 'adjust',
        payload: {'local_product_id': '44'},
        dependsOnEventId: 'missing-event',
      ),
      throwsStateError,
    );
  });

  test('an event cannot be rebound to a different business', () async {
    final eventId = await outbox.enqueue(
      businessId: 'business-a',
      entityType: 'product',
      localEntityId: '1',
      action: 'create',
      payload: {'name': 'قلم'},
    );

    await expectLater(
      outbox.bindEventToBusiness(
        eventId: eventId,
        businessId: 'business-b',
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
  });

  test('retries failed events with an incremented attempt count', () async {
    await outbox.enqueue(
      businessId: 'business-uuid',
      entityType: 'expense',
      localEntityId: '9',
      action: 'create',
      payload: {'amount_minor': 300},
    );

    final first = (await outbox.claimPendingBatch(businessId: 'business-uuid')).single;
    await outbox.markFailed(first.eventId, StateError('temporary network issue'));

    final retry = (await outbox.claimPendingBatch(businessId: 'business-uuid')).single;
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
      'remote-expense-id',
    );
    expect(
      await outbox.localIdFor(
        businessId: 'business-uuid',
        entityType: 'expense',
        remoteEntityId: 'remote-expense-id',
      ),
      '9',
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
    final event = (await outbox.claimPendingBatch(businessId: 'business-uuid')).single;
    await outbox.recordConflict(
      eventId: event.eventId,
      conflictType: 'remote_record_changed',
      remotePayload: {'price_minor': 2200},
    );

    expect(await outbox.claimPendingBatch(businessId: 'business-uuid'), isEmpty);
    final conflicts = await database.query('sync_conflicts');
    expect(conflicts, hasLength(1));
    expect(conflicts.single['conflict_type'], 'remote_record_changed');
    expect(conflicts.single['business_id'], 'business-uuid');
  });

  test('cannot record a conflict for an event that was not claimed', () async {
    final eventId = await outbox.enqueue(
      businessId: 'business-uuid',
      entityType: 'product',
      localEntityId: '8',
      action: 'update',
      payload: {'price_minor': 2200},
    );

    await expectLater(
      outbox.recordConflict(
        eventId: eventId,
        conflictType: 'remote_record_changed',
      ),
      throwsStateError,
    );
    expect(await database.query('sync_conflicts'), isEmpty);
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
