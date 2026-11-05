import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_inventory_write_repository.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sync_outbox_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _operationId = '8f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _productCloudId = '9f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _branchCloudId = 'af8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _warehouseCloudId = 'bf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _movementCloudId = 'cf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

class _RpcCall {
  const _RpcCall(this.function, this.parameters);
  final String function;
  final Map<String, dynamic> parameters;
}

class _FakeRpc implements CloudInventoryRpcClient {
  Object? result = _movementCloudId;
  final calls = <_RpcCall>[];

  @override
  Future<Object?> call(String function, Map<String, dynamic> parameters) async {
    calls.add(_RpcCall(function, Map<String, dynamic>.from(parameters)));
    return result;
  }
}

void main() {
  late Database database;
  late _FakeRpc rpc;
  late CloudInventoryWriteRepository repository;
  late SyncOutboxRepository outbox;
  late int productId;
  late int branchId;
  late int warehouseId;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, _businessId);
    final branch = (await database.query('branches', columns: ['id'])).single;
    branchId = branch['id']! as int;
    final warehouse = (await database.query(
      'warehouses',
      columns: ['id', 'branch_id'],
      where: 'branch_id = ?',
      whereArgs: [branchId],
    )).single;
    warehouseId = warehouse['id']! as int;
    productId = await ProductRepository(database).add(const Product(
      name: 'منتج المخزون',
      costMinor: 100,
      priceMinor: 150,
    ));
    outbox = SyncOutboxRepository(database);
    rpc = _FakeRpc();
    repository = CloudInventoryWriteRepository(database: database, rpc: rpc);
  });

  tearDown(() async => database.close());

  Future<void> addMappings({
    bool product = true,
    bool branch = true,
    bool warehouse = true,
  }) async {
    if (product) {
      await outbox.upsertEntityMapping(
        businessId: _businessId,
        entityType: 'product',
        localEntityId: productId.toString(),
        remoteEntityId: _productCloudId,
      );
    }
    if (branch) {
      await outbox.upsertEntityMapping(
        businessId: _businessId,
        entityType: 'branch',
        localEntityId: branchId.toString(),
        remoteEntityId: _branchCloudId,
      );
    }
    if (warehouse) {
      await outbox.upsertEntityMapping(
        businessId: _businessId,
        entityType: 'warehouse',
        localEntityId: warehouseId.toString(),
        remoteEntityId: _warehouseCloudId,
      );
    }
  }

  SyncOutboxEvent event({
    String? businessId = _businessId,
    Map<String, dynamic>? payload,
    String action = 'adjust',
    String entityType = 'inventory_movement',
    String operationId = _operationId,
    String localEntityId = '99',
    String? dependsOnEventId,
  }) {
    return SyncOutboxEvent(
      eventId: '7f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
      operationId: operationId,
      businessId: businessId,
      entityType: entityType,
      localEntityId: localEntityId,
      action: action,
      payload: payload ??
          {
            'payload_schema_version': 1,
            'local_product_id': productId.toString(),
            'local_warehouse_id': warehouseId.toString(),
            'quantity_delta': 3000,
            'reason': 'جرد',
          },
      status: 'processing',
      attempts: 1,
      dependsOnEventId: dependsOnEventId,
    );
  }

  test('maps inventory movement to the branch and warehouse aware RPC', () async {
    await addMappings();
    final movementId = await repository.adjustFromEvent(event());

    expect(movementId, _movementCloudId);
    expect(rpc.calls, hasLength(1));
    expect(rpc.calls.single.function, 'adjust_cloud_inventory');
    expect(rpc.calls.single.parameters, {
      'p_business_id': _businessId,
      'p_branch_id': _branchCloudId,
      'p_warehouse_id': _warehouseCloudId,
      'p_product_id': _productCloudId,
      'p_quantity_delta': 3000,
      'p_reason': 'جرد',
      'p_operation_id': _operationId,
    });
    expect(rpc.calls.single.parameters.values, isNot(contains('99')));
    expect(rpc.calls.single.parameters.values, isNot(contains(productId.toString())));
    expect(rpc.calls.single.parameters.values, isNot(contains(warehouseId.toString())));
  });

  test('refuses to call the server when any required mapping is missing', () async {
    await addMappings(product: false);
    await expectLater(repository.adjustFromEvent(event()), throwsStateError);
    expect(rpc.calls, isEmpty);

    await database.delete('sync_entity_map');
    await addMappings(product: true, branch: false, warehouse: true);
    await expectLater(repository.adjustFromEvent(event()), throwsStateError);
    expect(rpc.calls, isEmpty);

    await database.delete('sync_entity_map');
    await addMappings(product: true, branch: true, warehouse: false);
    await expectLater(repository.adjustFromEvent(event()), throwsStateError);
    expect(rpc.calls, isEmpty);
  });

  test('requires the dependent product event to be synced before inventory RPC', () async {
    await addMappings();
    final parentId = await outbox.enqueue(
      businessId: _businessId,
      entityType: 'product',
      localEntityId: productId.toString(),
      action: 'create',
      payload: {'name': 'منتج المخزون'},
    );
    final dependentEvent = event(dependsOnEventId: parentId);

    await expectLater(
      repository.adjustFromEvent(dependentEvent),
      throwsStateError,
    );
    expect(rpc.calls, isEmpty);

    final parent = (await outbox.claimPendingBatch(businessId: _businessId)).single;
    await outbox.markSynced(
      parent.eventId,
      remoteEntityId: _productCloudId,
    );
    final movementId = await repository.adjustFromEvent(dependentEvent);
    expect(movementId, _movementCloudId);
    expect(rpc.calls, hasLength(1));
  });

  test('rejects a local inactive warehouse or inactive product before RPC', () async {
    await addMappings();
    await database.update(
      'warehouses',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [warehouseId],
    );
    await expectLater(repository.adjustFromEvent(event()), throwsStateError);
    expect(rpc.calls, isEmpty);

    await database.update(
      'warehouses',
      {'is_active': 1},
      where: 'id = ?',
      whereArgs: [warehouseId],
    );
    await database.update(
      'products',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [productId],
    );
    await expectLater(repository.adjustFromEvent(event()), throwsStateError);
    expect(rpc.calls, isEmpty);
  });

  test('rejects malformed tenant, event, movement, and payload before RPC', () async {
    await addMappings();
    await expectLater(
      repository.adjustFromEvent(event(businessId: null)),
      throwsFormatException,
    );
    await expectLater(
      repository.adjustFromEvent(event(entityType: 'product')),
      throwsStateError,
    );
    await expectLater(
      repository.adjustFromEvent(event(operationId: 'not-a-uuid')),
      throwsFormatException,
    );
    await expectLater(
      repository.adjustFromEvent(event(localEntityId: 'movement-99')),
      throwsFormatException,
    );
    await expectLater(
      repository.adjustFromEvent(event(payload: {
        'payload_schema_version': 2,
        'local_product_id': productId.toString(),
        'local_warehouse_id': warehouseId.toString(),
        'quantity_delta': 10,
        'reason': 'جرد',
      })),
      throwsFormatException,
    );
    await expectLater(
      repository.adjustFromEvent(event(payload: {
        'payload_schema_version': 1,
        'local_product_id': productId.toString(),
        'local_warehouse_id': warehouseId.toString(),
        'quantity_delta': 0,
        'reason': 'جرد',
      })),
      throwsFormatException,
    );
    expect(rpc.calls, isEmpty);
  });

  test('rejects mappings that are not cloud UUIDs and invalid RPC results', () async {
    await addMappings();
    await database.update(
      'sync_entity_map',
      {'remote_entity_id': 'local-id-not-uuid'},
      where: 'business_id = ? AND entity_type = ?',
      whereArgs: [_businessId, 'warehouse'],
    );
    await expectLater(repository.adjustFromEvent(event()), throwsFormatException);
    expect(rpc.calls, isEmpty);

    await database.update(
      'sync_entity_map',
      {'remote_entity_id': _warehouseCloudId},
      where: 'business_id = ? AND entity_type = ?',
      whereArgs: [_businessId, 'warehouse'],
    );
    rpc.result = 'not-a-uuid';
    await expectLater(repository.adjustFromEvent(event()), throwsFormatException);
    expect(rpc.calls, hasLength(1));
  });
}
