import 'package:sqflite_common/sqlite_api.dart';

/// The selected local branch and warehouse inside one activity's SQLite file.
/// Cloud UUIDs are resolved only through explicit mappings; names are never
/// used to infer a relationship.
class LocalWorkspaceContext {
  const LocalWorkspaceContext({
    required this.businessId,
    required this.branchId,
    required this.warehouseId,
  });

  final String businessId;
  final int branchId;
  final int warehouseId;

  static Future<LocalWorkspaceContext> resolveFromCloudSelection({
    required Database database,
    required String businessId,
    required String cloudBranchId,
    required String cloudWarehouseId,
  }) async {
    final tenantId = businessId.trim().toLowerCase();
    if (tenantId.isEmpty ||
        cloudBranchId.trim().isEmpty ||
        cloudWarehouseId.trim().isEmpty) {
      throw ArgumentError('A business, branch and warehouse are required.');
    }

    final identity = await database.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (identity.isEmpty ||
        (identity.single['value']! as String).toLowerCase() != tenantId) {
      throw StateError('database_business_identity_mismatch');
    }

    final branchMappings = await database.query(
      'sync_entity_map',
      columns: ['local_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND remote_entity_id = ?',
      whereArgs: [tenantId, 'branch', cloudBranchId.trim().toLowerCase()],
      limit: 1,
    );
    final warehouseMappings = await database.query(
      'sync_entity_map',
      columns: ['local_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND remote_entity_id = ?',
      whereArgs: [tenantId, 'warehouse', cloudWarehouseId.trim().toLowerCase()],
      limit: 1,
    );
    if (branchMappings.isEmpty || warehouseMappings.isEmpty) {
      throw StateError('local_location_mapping_required');
    }

    final localBranchId =
        int.tryParse(branchMappings.single['local_entity_id']! as String);
    final localWarehouseId =
        int.tryParse(warehouseMappings.single['local_entity_id']! as String);
    if (localBranchId == null || localWarehouseId == null) {
      throw StateError('local_location_mapping_invalid');
    }

    final branchRows = await database.query(
      'branches',
      columns: ['id'],
      where: 'id = ? AND is_active = 1',
      whereArgs: [localBranchId],
      limit: 1,
    );
    final warehouseRows = await database.query(
      'warehouses',
      columns: ['id', 'branch_id'],
      where: 'id = ? AND is_active = 1',
      whereArgs: [localWarehouseId],
      limit: 1,
    );
    if (branchRows.isEmpty ||
        warehouseRows.isEmpty ||
        warehouseRows.single['branch_id'] != localBranchId) {
      throw StateError('local_location_mapping_mismatch');
    }

    return LocalWorkspaceContext(
      businessId: tenantId,
      branchId: localBranchId,
      warehouseId: localWarehouseId,
    );
  }
}
