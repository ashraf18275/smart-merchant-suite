import 'package:supabase_flutter/supabase_flutter.dart';

class CloudProduct {
  const CloudProduct({
    required this.id,
    required this.name,
    required this.sku,
    required this.costMinor,
    required this.priceMinor,
    required this.aggregateStockScaled,
    required this.warehouseStockScaled,
    required this.isActive,
  });
  final String id;
  final String name;
  final String? sku;
  final int costMinor;
  final int priceMinor;
  final int aggregateStockScaled;
  final int warehouseStockScaled;
  final bool isActive;

  factory CloudProduct.fromMap(Map<String, dynamic> row, {
    required int warehouseStockScaled,
  }) => CloudProduct(
    id: row['id'] as String,
    name: row['name'] as String,
    sku: row['sku'] as String?,
    costMinor: _asInt(row['cost_minor']),
    priceMinor: _asInt(row['price_minor']),
    aggregateStockScaled: _asInt(row['stock_quantity']),
    warehouseStockScaled: warehouseStockScaled,
    isActive: row['is_active'] == true,
  );

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) return value.toInt();
    throw FormatException('invalid_cloud_integer');
  }
}

class CloudProductWorkspace {
  const CloudProductWorkspace({
    required this.businessId,
    required this.branchId,
    required this.warehouseId,
    required this.products,
  });
  final String businessId;
  final String branchId;
  final String warehouseId;
  final List<CloudProduct> products;

  static bool canReadProducts({
    required bool actorIsOwner,
    required Set<String> permissions,
  }) => actorIsOwner ||
      const {'products.view', 'sales.create', 'inventory.view'}
          .intersection(permissions).isNotEmpty;
}

/// Read-only cloud catalogue access. It never writes SQLite or local product IDs.
class CloudProductRepository {
  CloudProductRepository(this._client);
  final SupabaseClient _client;

  Future<CloudProductWorkspace> load({
    required String businessId,
    required String branchId,
    required String warehouseId,
    bool includeInactive = false,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('authentication_required');
    if (businessId.trim().isEmpty || branchId.trim().isEmpty || warehouseId.trim().isEmpty) {
      throw ArgumentError('cloud_location_required');
    }
    final actor = await _client.from('business_members')
        .select('id,is_owner')
        .eq('business_id', businessId)
        .eq('user_id', user.id)
        .eq('is_active', true)
        .maybeSingle();
    if (actor == null) throw StateError('active_business_membership_required');

    final isOwner = actor['is_owner'] == true;
    final permissions = <String>{};
    if (!isOwner) {
      final grants = await _client.from('member_permissions')
          .select('permission_key')
          .eq('business_id', businessId)
          .eq('member_id', actor['id'])
          .eq('allowed', true);
      permissions.addAll(grants.map((row) => row['permission_key'] as String));
    }
    if (!CloudProductWorkspace.canReadProducts(
      actorIsOwner: isOwner,
      permissions: permissions,
    )) {
      throw StateError('products_view_permission_required');
    }

    final branch = await _client.from('cloud_branches')
        .select('id')
        .eq('business_id', businessId)
        .eq('id', branchId)
        .eq('is_active', true)
        .maybeSingle();
    if (branch == null) throw StateError('cloud_branch_unavailable');

    final warehouse = await _client.from('cloud_warehouses')
        .select('id')
        .eq('business_id', businessId)
        .eq('branch_id', branchId)
        .eq('id', warehouseId)
        .eq('is_active', true)
        .maybeSingle();
    if (warehouse == null) throw StateError('cloud_warehouse_unavailable');

    var productQuery = _client.from('cloud_products')
        .select('id,name,sku,cost_minor,price_minor,stock_quantity,is_active')
        .eq('business_id', businessId);
    if (!includeInactive) productQuery = productQuery.eq('is_active', true);
    final productRows = await productQuery.order('name');

    final stockRows = await _client.from('cloud_product_warehouse_stock')
        .select('product_id,quantity_scaled')
        .eq('business_id', businessId)
        .eq('branch_id', branchId)
        .eq('warehouse_id', warehouseId);
    final stockByProduct = <String, int>{
      for (final row in stockRows)
        row['product_id'] as String: CloudProduct._asInt(row['quantity_scaled']),
    };
    final products = productRows.map((row) => CloudProduct.fromMap(
      row,
      warehouseStockScaled: stockByProduct[row['id'] as String] ?? 0,
    )).toList(growable: false);

    return CloudProductWorkspace(
      businessId: businessId,
      branchId: branchId,
      warehouseId: warehouseId,
      products: products,
    );
  }
}
