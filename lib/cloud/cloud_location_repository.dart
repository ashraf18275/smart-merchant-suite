import 'package:supabase_flutter/supabase_flutter.dart';

class CloudBranch {
  const CloudBranch({
    required this.id,
    required this.name,
    required this.isActive,
    this.address,
    this.phone,
  });

  final String id;
  final String name;
  final bool isActive;
  final String? address;
  final String? phone;

  factory CloudBranch.fromMap(Map<String, dynamic> row) => CloudBranch(
        id: row['id'] as String,
        name: row['name'] as String,
        isActive: row['is_active'] == true,
        address: row['address'] as String?,
        phone: row['phone'] as String?,
      );
}

class CloudWarehouse {
  const CloudWarehouse({
    required this.id,
    required this.branchId,
    required this.name,
    required this.isActive,
  });

  final String id;
  final String branchId;
  final String name;
  final bool isActive;

  factory CloudWarehouse.fromMap(Map<String, dynamic> row) =>
      CloudWarehouse(
        id: row['id'] as String,
        branchId: row['branch_id'] as String,
        name: row['name'] as String,
        isActive: row['is_active'] == true,
      );
}

class CloudLocationWorkspace {
  const CloudLocationWorkspace({
    required this.branches,
    required this.warehouses,
    required this.actorIsOwner,
    required this.permissions,
  });

  final List<CloudBranch> branches;
  final List<CloudWarehouse> warehouses;
  final bool actorIsOwner;
  final Set<String> permissions;

  // Keep client visibility aligned with cloud_branches/cloud_warehouses RLS.
  // Operational permissions may read locations for their selectors even when
  // the member cannot manage the location records themselves.
  bool get canView => actorIsOwner ||
      const {
        'branches.view',
        'warehouses.view',
        'inventory.view',
        'sales.create',
        'products.view',
        'purchases.view',
        'purchases.create',
      }.intersection(permissions).isNotEmpty;
  bool get canManageBranches =>
      actorIsOwner || permissions.contains('branches.manage');
  bool get canManageWarehouses =>
      actorIsOwner || permissions.contains('warehouses.manage');
}

class CloudLocationRepository {
  CloudLocationRepository(this._client);

  final SupabaseClient _client;

  Future<CloudLocationWorkspace> load(String businessId) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('authentication_required');

    final actor = await _client
        .from('business_members')
        .select('id,is_owner')
        .eq('business_id', businessId)
        .eq('user_id', user.id)
        .eq('is_active', true)
        .single();

    final isOwner = actor['is_owner'] == true;
    final permissions = <String>{};
    if (!isOwner) {
      final grants = await _client
          .from('member_permissions')
          .select('permission_key')
          .eq('business_id', businessId)
          .eq('member_id', actor['id'])
          .eq('allowed', true);
      permissions.addAll(
        grants.map((row) => row['permission_key'] as String),
      );
    }

    final workspace = CloudLocationWorkspace(
      branches: const [],
      warehouses: const [],
      actorIsOwner: isOwner,
      permissions: permissions,
    );
    if (!workspace.canView) {
      throw StateError('locations_view_permission_required');
    }

    final branchRows = await _client
        .from('cloud_branches')
        .select('id,name,address,phone,is_active')
        .eq('business_id', businessId)
        .order('created_at');
    final warehouseRows = await _client
        .from('cloud_warehouses')
        .select('id,branch_id,name,is_active')
        .eq('business_id', businessId)
        .order('created_at');

    return CloudLocationWorkspace(
      branches: branchRows
          .map((row) => CloudBranch.fromMap(row))
          .toList(growable: false),
      warehouses: warehouseRows
          .map((row) => CloudWarehouse.fromMap(row))
          .toList(growable: false),
      actorIsOwner: isOwner,
      permissions: Set.unmodifiable(permissions),
    );
  }

  Future<String> createBranch({
    required String businessId,
    required String name,
    String? address,
    String? phone,
  }) async {
    final result = await _client.rpc(
      'create_cloud_branch',
      params: {
        'p_business_id': businessId,
        'p_name': name.trim(),
        'p_address': _cleanOptional(address),
        'p_phone': _cleanOptional(phone),
      },
    );
    return result as String;
  }

  Future<String> createWarehouse({
    required String businessId,
    required String branchId,
    required String name,
  }) async {
    final result = await _client.rpc(
      'create_cloud_warehouse',
      params: {
        'p_business_id': businessId,
        'p_branch_id': branchId,
        'p_name': name.trim(),
      },
    );
    return result as String;
  }

  Future<void> setBranchActive({
    required String businessId,
    required String branchId,
    required bool isActive,
  }) =>
      _client.rpc(
        'set_cloud_branch_active',
        params: {
          'p_business_id': businessId,
          'p_branch_id': branchId,
          'p_is_active': isActive,
        },
      );

  Future<void> setWarehouseActive({
    required String businessId,
    required String warehouseId,
    required bool isActive,
  }) =>
      _client.rpc(
        'set_cloud_warehouse_active',
        params: {
          'p_business_id': businessId,
          'p_warehouse_id': warehouseId,
          'p_is_active': isActive,
        },
      );

  String? _cleanOptional(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }
}
