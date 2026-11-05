import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/cloud/cloud_location_mapping_repository.dart';
import 'package:smart_merchant_suite/cloud/cloud_location_repository.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _cloudBranchA = '8f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _cloudBranchB = '9f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _cloudWarehouseA = 'af8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const _cloudWarehouseB = 'bf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

class _FakeRemote implements CloudLocationMappingRemote {
  final branches = <String, CloudBranch>{
    _cloudBranchA: const CloudBranch(
      id: _cloudBranchA,
      name: 'Cloud Main Branch',
      isActive: true,
    ),
    _cloudBranchB: const CloudBranch(
      id: _cloudBranchB,
      name: 'Remote Branch B',
      isActive: true,
    ),
  };
  final warehouses = <String, CloudWarehouse>{
    _cloudWarehouseA: const CloudWarehouse(
      id: _cloudWarehouseA,
      branchId: _cloudBranchA,
      name: 'Cloud Main Warehouse',
      isActive: true,
    ),
    _cloudWarehouseB: const CloudWarehouse(
      id: _cloudWarehouseB,
      branchId: _cloudBranchB,
      name: 'Remote Warehouse B',
      isActive: true,
    ),
  };

  @override
  Future<CloudBranch?> activeBranch({
    required String businessId,
    required String branchId,
  }) async => businessId == _businessId ? branches[branchId] : null;

  @override
  Future<CloudWarehouse?> activeWarehouse({
    required String businessId,
    required String warehouseId,
  }) async => businessId == _businessId ? warehouses[warehouseId] : null;
}

void main() {
  late Database database;
  late _FakeRemote remote;
  late CloudLocationMappingRepository repository;
  late int localBranchId;
  late int localWarehouseId;
  late int secondLocalBranchId;
  late int secondLocalWarehouseId;

  const ownerWorkspace = CloudLocationWorkspace(
    branches: [],
    warehouses: [],
    actorIsOwner: true,
    permissions: {},
  );

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, _businessId);
    localBranchId = (await database.query(
      'branches',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: ['الفرع الرئيسي'],
    )).single['id']! as int;
    localWarehouseId = (await database.query(
      'warehouses',
      columns: ['id'],
      where: 'name = ? AND branch_id = ?',
      whereArgs: ['المخزن الرئيسي', localBranchId],
    )).single['id']! as int;
    secondLocalBranchId = await database.insert('branches', {
      'name': 'فرع محلي ثان',
      'is_active': 1,
      'created_at': DateTime.utc(2026).toIso8601String(),
    });
    secondLocalWarehouseId = await database.insert('warehouses', {
      'branch_id': secondLocalBranchId,
      'name': 'مخزن محلي ثان',
      'is_active': 1,
      'created_at': DateTime.utc(2026).toIso8601String(),
    });
    remote = _FakeRemote();
    repository = CloudLocationMappingRepository(
      database: database,
      remote: remote,
      workspace: ownerWorkspace,
    );
  });

  tearDown(() async => database.close());

  test('maps an explicitly selected local branch without matching names', () async {
    await repository.mapLocalBranch(
      businessId: _businessId,
      localBranchId: localBranchId,
      cloudBranchId: _cloudBranchA,
      explicitlyConfirmed: true,
    );

    final mapping = await database.query(
      'sync_entity_map',
      where: 'business_id = ? AND entity_type = ? AND local_entity_id = ?',
      whereArgs: [_businessId, 'branch', localBranchId.toString()],
    );
    expect(mapping.single['remote_entity_id'], _cloudBranchA);
    final snapshot = await repository.loadSnapshot(businessId: _businessId);
    expect(snapshot.branches.singleWhere((b) => b.id == localBranchId).cloudId,
        _cloudBranchA);
  });

  test('requires explicit confirmation and branch management permission', () async {
    await expectLater(
      repository.mapLocalBranch(
        businessId: _businessId,
        localBranchId: localBranchId,
        cloudBranchId: _cloudBranchA,
        explicitlyConfirmed: false,
      ),
      throwsStateError,
    );

    final readOnly = CloudLocationMappingRepository(
      database: database,
      remote: remote,
      workspace: const CloudLocationWorkspace(
        branches: [],
        warehouses: [],
        actorIsOwner: false,
        permissions: {'branches.view', 'warehouses.view'},
      ),
    );
    await expectLater(
      readOnly.mapLocalBranch(
        businessId: _businessId,
        localBranchId: localBranchId,
        cloudBranchId: _cloudBranchA,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    expect(await database.query('sync_entity_map'), isEmpty);
  });

  test('rejects a cloud branch outside the database tenant and an identity mismatch', () async {
    await expectLater(
      repository.mapLocalBranch(
        businessId: '7f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
        localBranchId: localBranchId,
        cloudBranchId: _cloudBranchA,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    await expectLater(
      repository.mapLocalBranch(
        businessId: _businessId,
        localBranchId: localBranchId,
        cloudBranchId: 'cf8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    expect(await database.query('sync_entity_map'), isEmpty);
  });

  test('prevents inactive local branches and remapping to another cloud branch', () async {
    final inactiveId = await database.insert('branches', {
      'name': 'فرع متوقف',
      'is_active': 0,
      'created_at': DateTime.utc(2026).toIso8601String(),
    });
    await expectLater(
      repository.mapLocalBranch(
        businessId: _businessId,
        localBranchId: inactiveId,
        cloudBranchId: _cloudBranchA,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );

    await repository.mapLocalBranch(
      businessId: _businessId,
      localBranchId: localBranchId,
      cloudBranchId: _cloudBranchA,
      explicitlyConfirmed: true,
    );
    await expectLater(
      repository.mapLocalBranch(
        businessId: _businessId,
        localBranchId: localBranchId,
        cloudBranchId: _cloudBranchB,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    expect(await database.query('sync_entity_map'), hasLength(1));
  });

  test('warehouse mapping requires the local branch mapping and matching cloud parent', () async {
    await expectLater(
      repository.mapLocalWarehouse(
        businessId: _businessId,
        localWarehouseId: localWarehouseId,
        cloudWarehouseId: _cloudWarehouseA,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );

    await repository.mapLocalBranch(
      businessId: _businessId,
      localBranchId: localBranchId,
      cloudBranchId: _cloudBranchA,
      explicitlyConfirmed: true,
    );

    await expectLater(
      repository.mapLocalWarehouse(
        businessId: _businessId,
        localWarehouseId: localWarehouseId,
        cloudWarehouseId: _cloudWarehouseB,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    expect(await database.query('sync_entity_map'), hasLength(1));
  });

  test('maps a warehouse only after its branch and cloud parent are validated', () async {
    await repository.mapLocalBranch(
      businessId: _businessId,
      localBranchId: localBranchId,
      cloudBranchId: _cloudBranchA,
      explicitlyConfirmed: true,
    );
    await repository.mapLocalWarehouse(
      businessId: _businessId,
      localWarehouseId: localWarehouseId,
      cloudWarehouseId: _cloudWarehouseA,
      explicitlyConfirmed: true,
    );

    final snapshot = await repository.loadSnapshot(businessId: _businessId);
    expect(snapshot.warehouses.singleWhere((w) => w.id == localWarehouseId).cloudId,
        _cloudWarehouseA);
    expect(await database.query('sync_entity_map'), hasLength(2));
  });

  test('prevents two local locations from sharing one cloud location UUID', () async {
    await repository.mapLocalBranch(
      businessId: _businessId,
      localBranchId: localBranchId,
      cloudBranchId: _cloudBranchA,
      explicitlyConfirmed: true,
    );
    await expectLater(
      repository.mapLocalBranch(
        businessId: _businessId,
        localBranchId: secondLocalBranchId,
        cloudBranchId: _cloudBranchA,
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    expect(await database.query('sync_entity_map'), hasLength(1));
    expect(secondLocalWarehouseId, isPositive);
  });
}
