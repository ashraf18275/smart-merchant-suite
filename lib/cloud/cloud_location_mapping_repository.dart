import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_location_repository.dart';

abstract interface class CloudLocationMappingRemote {
  Future<CloudBranch?> activeBranch({
    required String businessId,
    required String branchId,
  });

  Future<CloudWarehouse?> activeWarehouse({
    required String businessId,
    required String warehouseId,
  });
}

class SupabaseCloudLocationMappingRemote
    implements CloudLocationMappingRemote {
  SupabaseCloudLocationMappingRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<CloudBranch?> activeBranch({
    required String businessId,
    required String branchId,
  }) async {
    final row = await _client
        .from('cloud_branches')
        .select('id,name,address,phone,is_active')
        .eq('business_id', businessId)
        .eq('id', branchId)
        .eq('is_active', true)
        .maybeSingle();
    return row == null ? null : CloudBranch.fromMap(row);
  }

  @override
  Future<CloudWarehouse?> activeWarehouse({
    required String businessId,
    required String warehouseId,
  }) async {
    final row = await _client
        .from('cloud_warehouses')
        .select('id,branch_id,name,is_active')
        .eq('business_id', businessId)
        .eq('id', warehouseId)
        .eq('is_active', true)
        .maybeSingle();
    return row == null ? null : CloudWarehouse.fromMap(row);
  }
}

class LocalBranchMapping {
  const LocalBranchMapping({
    required this.id,
    required this.name,
    required this.isActive,
    this.cloudId,
  });

  final int id;
  final String name;
  final bool isActive;
  final String? cloudId;
}

class LocalWarehouseMapping {
  const LocalWarehouseMapping({
    required this.id,
    required this.branchId,
    required this.name,
    required this.isActive,
    this.cloudId,
  });

  final int id;
  final int branchId;
  final String name;
  final bool isActive;
  final String? cloudId;
}

class CloudLocationMappingSnapshot {
  const CloudLocationMappingSnapshot({
    required this.branches,
    required this.warehouses,
  });

  final List<LocalBranchMapping> branches;
  final List<LocalWarehouseMapping> warehouses;
}

/// Explicitly maps local SQLite locations to cloud UUIDs. It never matches
/// records by name and never creates, moves, or copies business data.
class CloudLocationMappingRepository {
  CloudLocationMappingRepository({
    required Database database,
    required CloudLocationMappingRemote remote,
    required CloudLocationWorkspace workspace,
  })  : _database = database,
        _remote = remote,
        _workspace = workspace;

  final Database _database;
  final CloudLocationMappingRemote _remote;
  final CloudLocationWorkspace _workspace;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Future<CloudLocationMappingSnapshot> loadSnapshot({
    required String businessId,
  }) async {
    _requirePermission(_workspace.canView, 'locations_view_permission_required');
    final tenantId = await _requireCurrentBusiness(businessId);
    final branchRows = await _database.query(
      'branches',
      columns: ['id', 'name', 'is_active'],
      orderBy: 'id ASC',
    );
    final warehouseRows = await _database.query(
      'warehouses',
      columns: ['id', 'branch_id', 'name', 'is_active'],
      orderBy: 'id ASC',
    );
    final mappingRows = await _database.query(
      'sync_entity_map',
      columns: ['entity_type', 'local_entity_id', 'remote_entity_id'],
      where: 'business_id = ? AND entity_type IN (?, ?)',
      whereArgs: [tenantId, 'branch', 'warehouse'],
    );
    final branchMap = <int, String>{};
    final warehouseMap = <int, String>{};
    for (final row in mappingRows) {
      final localId = int.tryParse(row['local_entity_id']! as String);
      final remoteId = row['remote_entity_id']! as String;
      if (localId == null) continue;
      if (row['entity_type'] == 'branch') {
        branchMap[localId] = remoteId;
      } else if (row['entity_type'] == 'warehouse') {
        warehouseMap[localId] = remoteId;
      }
    }
    return CloudLocationMappingSnapshot(
      branches: branchRows
          .map((row) => LocalBranchMapping(
                id: row['id']! as int,
                name: row['name']! as String,
                isActive: row['is_active'] == 1,
                cloudId: branchMap[row['id']! as int],
              ))
          .toList(growable: false),
      warehouses: warehouseRows
          .map((row) => LocalWarehouseMapping(
                id: row['id']! as int,
                branchId: row['branch_id']! as int,
                name: row['name']! as String,
                isActive: row['is_active'] == 1,
                cloudId: warehouseMap[row['id']! as int],
              ))
          .toList(growable: false),
    );
  }

  Future<void> mapLocalBranch({
    required String businessId,
    required int localBranchId,
    required String cloudBranchId,
    required bool explicitlyConfirmed,
  }) async {
    _requirePermission(
      _workspace.canManageBranches,
      'branches_manage_permission_required',
    );
    if (!explicitlyConfirmed) {
      throw StateError('location_mapping_requires_explicit_confirmation');
    }
    final tenantId = await _requireCurrentBusiness(businessId);
    final remoteId = _requireUuid(cloudBranchId, 'cloud_branch_id');
    final remoteBranch = await _remote.activeBranch(
      businessId: tenantId,
      branchId: remoteId,
    );
    if (remoteBranch == null || remoteBranch.id.toLowerCase() != remoteId) {
      throw StateError('cloud_branch_unavailable');
    }

    await _database.transaction((txn) async {
      await _requireCurrentBusiness(tenantId, executor: txn);
      final localRows = await txn.query(
        'branches',
        columns: ['id', 'is_active'],
        where: 'id = ?',
        whereArgs: [localBranchId],
        limit: 1,
      );
      if (localRows.isEmpty || localRows.single['is_active'] != 1) {
        throw StateError('local_branch_unavailable');
      }
      await _writeMapping(
        txn,
        businessId: tenantId,
        entityType: 'branch',
        localEntityId: localBranchId.toString(),
        remoteEntityId: remoteId,
      );
    });
  }

  Future<void> mapLocalWarehouse({
    required String businessId,
    required int localWarehouseId,
    required String cloudWarehouseId,
    required bool explicitlyConfirmed,
  }) async {
    _requirePermission(
      _workspace.canManageWarehouses,
      'warehouses_manage_permission_required',
    );
    if (!explicitlyConfirmed) {
      throw StateError('location_mapping_requires_explicit_confirmation');
    }
    final tenantId = await _requireCurrentBusiness(businessId);
    final remoteId = _requireUuid(cloudWarehouseId, 'cloud_warehouse_id');
    final remoteWarehouse = await _remote.activeWarehouse(
      businessId: tenantId,
      warehouseId: remoteId,
    );
    if (remoteWarehouse == null || remoteWarehouse.id.toLowerCase() != remoteId) {
      throw StateError('cloud_warehouse_unavailable');
    }
    final remoteBranch = await _remote.activeBranch(
      businessId: tenantId,
      branchId: remoteWarehouse.branchId,
    );
    if (remoteBranch == null) {
      throw StateError('cloud_warehouse_parent_branch_unavailable');
    }

    await _database.transaction((txn) async {
      await _requireCurrentBusiness(tenantId, executor: txn);
      final localRows = await txn.query(
        'warehouses',
        columns: ['branch_id', 'is_active'],
        where: 'id = ?',
        whereArgs: [localWarehouseId],
        limit: 1,
      );
      if (localRows.isEmpty || localRows.single['is_active'] != 1) {
        throw StateError('local_warehouse_unavailable');
      }
      final localBranchId = localRows.single['branch_id']! as int;
      final localBranchRows = await txn.query(
        'branches',
        columns: ['is_active'],
        where: 'id = ?',
        whereArgs: [localBranchId],
        limit: 1,
      );
      if (localBranchRows.isEmpty || localBranchRows.single['is_active'] != 1) {
        throw StateError('local_warehouse_parent_branch_unavailable');
      }
      final branchMappings = await txn.query(
        'sync_entity_map',
        columns: ['remote_entity_id'],
        where: 'business_id = ? AND entity_type = ? AND local_entity_id = ?',
        whereArgs: [tenantId, 'branch', localBranchId.toString()],
        limit: 1,
      );
      if (branchMappings.isEmpty ||
          branchMappings.single['remote_entity_id'] != remoteWarehouse.branchId) {
        throw StateError('local_warehouse_branch_mapping_mismatch');
      }
      await _writeMapping(
        txn,
        businessId: tenantId,
        entityType: 'warehouse',
        localEntityId: localWarehouseId.toString(),
        remoteEntityId: remoteId,
      );
    });
  }

  Future<String> _requireCurrentBusiness(
    String businessId, {
    DatabaseExecutor? executor,
  }) async {
    final tenantId = _requireUuid(businessId, 'business_id');
    final rows = await (executor ?? _database).query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (rows.isEmpty ||
        (rows.single['value']! as String).trim().toLowerCase() != tenantId) {
      throw StateError('database_business_identity_mismatch');
    }
    return tenantId;
  }

  String _requireUuid(String value, String label) {
    final normalized = value.trim().toLowerCase();
    if (!_uuidPattern.hasMatch(normalized)) {
      throw FormatException('invalid_$label');
    }
    return normalized;
  }

  void _requirePermission(bool allowed, String errorCode) {
    if (!allowed) throw StateError(errorCode);
  }

  Future<void> _writeMapping(
    DatabaseExecutor txn, {
    required String businessId,
    required String entityType,
    required String localEntityId,
    required String remoteEntityId,
  }) async {
    final localRows = await txn.query(
      'sync_entity_map',
      columns: ['remote_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND local_entity_id = ?',
      whereArgs: [businessId, entityType, localEntityId],
      limit: 1,
    );
    if (localRows.isNotEmpty &&
        localRows.single['remote_entity_id'] != remoteEntityId) {
      throw StateError('local_location_already_mapped');
    }
    final remoteRows = await txn.query(
      'sync_entity_map',
      columns: ['local_entity_id'],
      where: 'business_id = ? AND entity_type = ? AND remote_entity_id = ?',
      whereArgs: [businessId, entityType, remoteEntityId],
      limit: 1,
    );
    if (remoteRows.isNotEmpty &&
        remoteRows.single['local_entity_id'] != localEntityId) {
      throw StateError('cloud_location_already_mapped');
    }
    if (localRows.isEmpty) {
      final now = DateTime.now().toUtc().toIso8601String();
      await txn.insert('sync_entity_map', {
        'business_id': businessId,
        'entity_type': entityType,
        'local_entity_id': localEntityId,
        'remote_entity_id': remoteEntityId,
        'created_at': now,
        'updated_at': now,
      });
    }
  }
}
