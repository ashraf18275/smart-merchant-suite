import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/sync_outbox_repository.dart';

abstract interface class CloudInventoryRpcClient {
  Future<Object?> call(String function, Map<String, dynamic> parameters);
}

class SupabaseCloudInventoryRpcClient implements CloudInventoryRpcClient {
  SupabaseCloudInventoryRpcClient(this._client);

  final SupabaseClient _client;

  @override
  Future<Object?> call(
    String function,
    Map<String, dynamic> parameters,
  ) async {
    return await _client.rpc(function, params: parameters);
  }
}

/// Converts a local inventory movement event to the tenant- and
/// warehouse-scoped idempotent inventory RPC. This is an adapter only; it is
/// not wired to an automatic sender.
class CloudInventoryWriteRepository {
  CloudInventoryWriteRepository({
    required Database database,
    required CloudInventoryRpcClient rpc,
  })  : _database = database,
        _rpc = rpc,
        _outbox = SyncOutboxRepository(database);

  final Database _database;
  final CloudInventoryRpcClient _rpc;
  final SyncOutboxRepository _outbox;

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  Future<String> adjustFromEvent(SyncOutboxEvent event) async {
    if (event.entityType != 'inventory_movement' || event.action != 'adjust') {
      throw StateError('unsupported_inventory_outbox_event');
    }
    if (event.payload['payload_schema_version'] != 1) {
      throw FormatException('unsupported_inventory_payload_schema');
    }
    final businessId = _requireUuid(event.businessId, 'business_id');
    final operationId = _requireUuid(event.operationId, 'operation_id');
    final movementId = _parseLocalId(event.localEntityId, 'movement_id');
    final productLocalId =
        _parseLocalId(event.payload['local_product_id'], 'local_product_id');
    final warehouseLocalId =
        _parseLocalId(event.payload['local_warehouse_id'], 'local_warehouse_id');
    final quantityDelta = event.payload['quantity_delta'];
    final reason = event.payload['reason'];
    if (quantityDelta is! int || quantityDelta == 0) {
      throw FormatException('invalid_inventory_quantity_delta');
    }
    if (reason is! String || reason.trim().isEmpty || reason.trim().length > 250) {
      throw FormatException('invalid_inventory_reason');
    }

    await _requireCurrentBusiness(businessId);
    await _requireDependencySynced(event, businessId);
    final warehouseRows = await _database.query(
      'warehouses',
      columns: ['branch_id', 'is_active'],
      where: 'id = ?',
      whereArgs: [warehouseLocalId],
      limit: 1,
    );
    if (warehouseRows.isEmpty || warehouseRows.single['is_active'] != 1) {
      throw StateError('local_warehouse_unavailable');
    }
    final localBranchId = warehouseRows.single['branch_id']! as int;
    final branchRows = await _database.query(
      'branches',
      columns: ['is_active'],
      where: 'id = ?',
      whereArgs: [localBranchId],
      limit: 1,
    );
    if (branchRows.isEmpty || branchRows.single['is_active'] != 1) {
      throw StateError('local_branch_unavailable');
    }
    final productRows = await _database.query(
      'products',
      columns: ['is_active'],
      where: 'id = ?',
      whereArgs: [productLocalId],
      limit: 1,
    );
    if (productRows.isEmpty || productRows.single['is_active'] != 1) {
      throw StateError('local_product_unavailable');
    }

    final productCloudId = await _mappedUuid(
      businessId: businessId,
      entityType: 'product',
      localEntityId: productLocalId.toString(),
      label: 'product',
    );
    final branchCloudId = await _mappedUuid(
      businessId: businessId,
      entityType: 'branch',
      localEntityId: localBranchId.toString(),
      label: 'branch',
    );
    final warehouseCloudId = await _mappedUuid(
      businessId: businessId,
      entityType: 'warehouse',
      localEntityId: warehouseLocalId.toString(),
      label: 'warehouse',
    );

    final result = await _rpc.call('adjust_cloud_inventory', {
      'p_business_id': businessId,
      'p_branch_id': branchCloudId,
      'p_warehouse_id': warehouseCloudId,
      'p_product_id': productCloudId,
      'p_quantity_delta': quantityDelta,
      'p_reason': reason.trim(),
      'p_operation_id': operationId,
    });
    return _readRemoteId(result);
  }

  Future<String> _mappedUuid({
    required String businessId,
    required String entityType,
    required String localEntityId,
    required String label,
  }) async {
    final remoteId = await _outbox.remoteIdFor(
      businessId: businessId,
      entityType: entityType,
      localEntityId: localEntityId,
    );
    if (remoteId == null) throw StateError('missing_${label}_mapping');
    return _requireUuid(remoteId, 'remote_${label}_id');
  }

  Future<void> _requireDependencySynced(
    SyncOutboxEvent event,
    String businessId,
  ) async {
    final dependencyId = event.dependsOnEventId;
    if (dependencyId == null) return;
    final rows = await _database.query(
      'sync_outbox',
      columns: ['business_id', 'status'],
      where: 'event_id = ?',
      whereArgs: [dependencyId],
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.single['business_id'] != businessId ||
        rows.single['status'] != 'synced') {
      throw StateError('inventory_dependency_not_synced');
    }
  }

  Future<void> _requireCurrentBusiness(String businessId) async {
    final rows = await _database.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['database_business_id'],
      limit: 1,
    );
    if (rows.isEmpty ||
        (rows.single['value']! as String).trim().toLowerCase() != businessId) {
      throw StateError('database_business_identity_mismatch');
    }
  }

  int _parseLocalId(Object? value, String label) {
    final id = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (id == null || id <= 0) throw FormatException('invalid_$label');
    return id;
  }

  String _requireUuid(String? value, String label) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || !_uuidPattern.hasMatch(normalized)) {
      throw FormatException('invalid_$label');
    }
    return normalized;
  }

  String _readRemoteId(Object? value) {
    if (value is! String) {
      throw FormatException('invalid_cloud_inventory_rpc_result');
    }
    return _requireUuid(value, 'remote_movement_id');
  }
}
