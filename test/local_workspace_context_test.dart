import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/business_database_identity.dart';
import 'package:smart_merchant_suite/data/local_workspace_context.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const businessId = '6f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const cloudBranchId = '8f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';
const cloudWarehouseId = 'af8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d';

void main() {
  late Database database;
  late int localBranchId;
  late int localWarehouseId;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    await ensureBusinessDatabaseIdentity(database, businessId);
    localBranchId = (await database.query(
      'branches',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: ['الفرع الرئيسي'],
    )).single['id']! as int;
    localWarehouseId = (await database.query(
      'warehouses',
      columns: ['id'],
      where: 'branch_id = ?',
      whereArgs: [localBranchId],
    )).single['id']! as int;
    final now = DateTime.utc(2026).toIso8601String();
    await database.insert('sync_entity_map', {
      'business_id': businessId,
      'entity_type': 'branch',
      'local_entity_id': localBranchId.toString(),
      'remote_entity_id': cloudBranchId,
      'created_at': now,
      'updated_at': now,
    });
    await database.insert('sync_entity_map', {
      'business_id': businessId,
      'entity_type': 'warehouse',
      'local_entity_id': localWarehouseId.toString(),
      'remote_entity_id': cloudWarehouseId,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async => database.close());

  test('resolves only explicitly mapped local branch and warehouse IDs', () async {
    final resolved = await LocalWorkspaceContext.resolveFromCloudSelection(
      database: database,
      businessId: businessId,
      cloudBranchId: cloudBranchId,
      cloudWarehouseId: cloudWarehouseId,
    );

    expect(resolved.businessId, businessId);
    expect(resolved.branchId, localBranchId);
    expect(resolved.warehouseId, localWarehouseId);
  });

  test('refuses an unmapped cloud location instead of guessing by name', () async {
    await expectLater(
      LocalWorkspaceContext.resolveFromCloudSelection(
        database: database,
        businessId: businessId,
        cloudBranchId: '9f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
        cloudWarehouseId: cloudWarehouseId,
      ),
      throwsStateError,
    );
  });

  test('refuses a database belonging to another business', () async {
    await expectLater(
      LocalWorkspaceContext.resolveFromCloudSelection(
        database: database,
        businessId: '7f8f5771-3a1b-4b2a-9c7d-1d0e4a5b6c7d',
        cloudBranchId: cloudBranchId,
        cloudWarehouseId: cloudWarehouseId,
      ),
      throwsStateError,
    );
  });

  test('refuses a warehouse mapped beneath a different local branch', () async {
    final otherBranchId = await database.insert('branches', {
      'name': 'فرع آخر',
      'is_active': 1,
      'created_at': DateTime.utc(2026).toIso8601String(),
    });
    final otherWarehouseId = await database.insert('warehouses', {
      'branch_id': otherBranchId,
      'name': 'مخزن آخر',
      'is_active': 1,
      'created_at': DateTime.utc(2026).toIso8601String(),
    });
    await database.update(
      'sync_entity_map',
      {'local_entity_id': otherWarehouseId.toString()},
      where: 'business_id = ? AND entity_type = ?',
      whereArgs: [businessId, 'warehouse'],
    );

    await expectLater(
      LocalWorkspaceContext.resolveFromCloudSelection(
        database: database,
        businessId: businessId,
        cloudBranchId: cloudBranchId,
        cloudWarehouseId: cloudWarehouseId,
      ),
      throwsStateError,
    );
  });
}
