import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import 'cloud_location_repository.dart';

/// The selected cloud tenant and location for this signed-in user on this
/// device. Cloud UUIDs are deliberately kept separate from local SQLite IDs.
class CloudWorkspaceContext {
  const CloudWorkspaceContext({
    required this.businessId,
    required this.branchId,
    required this.warehouseId,
  });

  final String businessId;
  final String branchId;
  final String? warehouseId;

  static CloudWorkspaceContext? resolve({
    required String businessId,
    required List<CloudBranch> branches,
    required List<CloudWarehouse> warehouses,
    CloudWorkspaceContext? previous,
  }) {
    final activeBranches = branches.where((branch) => branch.isActive).toList();
    if (activeBranches.isEmpty) return null;

    final activeWarehouses =
        warehouses.where((warehouse) => warehouse.isActive).toList();

    CloudBranch? selectedBranch;
    if (previous != null && previous.businessId == businessId) {
      for (final branch in activeBranches) {
        if (branch.id == previous.branchId) {
          selectedBranch = branch;
          break;
        }
      }
    }

    selectedBranch ??= activeBranches.firstWhere(
      (branch) => activeWarehouses.any(
        (warehouse) => warehouse.branchId == branch.id,
      ),
      orElse: () => activeBranches.first,
    );

    final branchWarehouses = activeWarehouses
        .where((warehouse) => warehouse.branchId == selectedBranch!.id)
        .toList();

    String? warehouseId;
    if (previous != null &&
        previous.businessId == businessId &&
        previous.branchId == selectedBranch.id &&
        branchWarehouses.any((warehouse) => warehouse.id == previous.warehouseId)) {
      warehouseId = previous.warehouseId;
    } else if (branchWarehouses.isNotEmpty) {
      warehouseId = branchWarehouses.first.id;
    }

    return CloudWorkspaceContext(
      businessId: businessId,
      branchId: selectedBranch.id,
      warehouseId: warehouseId,
    );
  }

  bool isValidFor({
    required String expectedBusinessId,
    required List<CloudBranch> branches,
    required List<CloudWarehouse> warehouses,
  }) {
    if (businessId != expectedBusinessId) return false;
    final branchIsActive = branches.any(
      (branch) => branch.id == branchId && branch.isActive,
    );
    if (!branchIsActive) return false;
    if (warehouseId == null) return true;
    return warehouses.any(
      (warehouse) =>
          warehouse.id == warehouseId &&
          warehouse.branchId == branchId &&
          warehouse.isActive,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CloudWorkspaceContext &&
      other.businessId == businessId &&
      other.branchId == branchId &&
      other.warehouseId == warehouseId;

  @override
  int get hashCode => Object.hash(businessId, branchId, warehouseId);
}

/// Stores only the user's cloud workspace selection in the existing local
/// sync_metadata key/value table. This is a device preference, not a sync job.
class CloudWorkspaceContextRepository {
  CloudWorkspaceContextRepository(this._database);

  final Database _database;

  String _key(String userId, String businessId) =>
      'cloud_workspace_context:$userId:$businessId';

  Future<CloudWorkspaceContext?> load({
    required String userId,
    required String businessId,
  }) async {
    final rows = await _database.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_key(userId, businessId)],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    try {
      final decoded = jsonDecode(rows.single['value']! as String);
      if (decoded is! Map<String, dynamic>) return null;
      final branchId = decoded['branch_id'];
      final warehouseId = decoded['warehouse_id'];
      if (branchId is! String ||
          branchId.trim().isEmpty ||
          (warehouseId != null &&
              (warehouseId is! String || warehouseId.trim().isEmpty))) {
        return null;
      }
      return CloudWorkspaceContext(
        businessId: businessId,
        branchId: branchId,
        warehouseId: warehouseId as String?,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> save({
    required String userId,
    required CloudWorkspaceContext selection,
  }) async {
    if (userId.trim().isEmpty ||
        selection.businessId.trim().isEmpty ||
        selection.branchId.trim().isEmpty ||
        (selection.warehouseId != null &&
            selection.warehouseId!.trim().isEmpty)) {
      throw ArgumentError(
        'A valid user, business, branch and optional warehouse are required.',
      );
    }

    await _database.insert(
      'sync_metadata',
      {
        'key': _key(userId, selection.businessId),
        'value': jsonEncode({
          'branch_id': selection.branchId,
          'warehouse_id': selection.warehouseId,
        }),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clear({
    required String userId,
    required String businessId,
  }) async {
    await _database.delete(
      'sync_metadata',
      where: 'key = ?',
      whereArgs: [_key(userId, businessId)],
    );
  }
}
