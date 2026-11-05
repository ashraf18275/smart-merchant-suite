import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_location_repository.dart';
import '../cloud/cloud_product_repository.dart';
import '../core/quantity.dart';

// Cloud catalogue presentation remains intentionally read-only until sync is verified.
class CloudProductsPage extends StatefulWidget {
  const CloudProductsPage({
    super.key,
    required this.client,
    required this.businessId,
    required this.businessName,
  });
  final SupabaseClient client;
  final String businessId;
  final String businessName;

  @override
  State<CloudProductsPage> createState() => _CloudProductsPageState();
}

class _CloudProductsPageState extends State<CloudProductsPage> {
  late final CloudLocationRepository _locations = CloudLocationRepository(widget.client);
  late final CloudProductRepository _products = CloudProductRepository(widget.client);
  CloudLocationWorkspace? _locationWorkspace;
  CloudProductWorkspace? _productWorkspace;
  String? _branchId;
  String? _warehouseId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    setState(() { _loading = true; _error = null; });
    try {
      final workspace = await _locations.load(widget.businessId);
      final activeBranches = workspace.branches.where((item) => item.isActive);
      final branchId = activeBranches.any((item) => item.id == _branchId)
          ? _branchId
          : activeBranches.firstOrNull?.id;
      final activeWarehouses = workspace.warehouses.where(
        (item) => item.branchId == branchId && item.isActive,
      );
      final warehouseId = activeWarehouses.any((item) => item.id == _warehouseId)
          ? _warehouseId
          : activeWarehouses.firstOrNull?.id;
      if (!mounted) return;
      setState(() {
        _locationWorkspace = workspace;
        _branchId = branchId;
        _warehouseId = warehouseId;
      });
      await _loadProducts();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadProducts() async {
    final branchId = _branchId;
    final warehouseId = _warehouseId;
    if (branchId == null || warehouseId == null) {
      if (mounted) setState(() => _productWorkspace = null);
      return;
    }
    try {
      final workspace = await _products.load(
        businessId: widget.businessId,
        branchId: branchId,
        warehouseId: warehouseId,
      );
      if (mounted) setState(() => _productWorkspace = workspace);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _selectBranch(String? value) async {
    if (value == null || value == _branchId) return;
    final warehouse = _locationWorkspace?.warehouses.where(
      (item) => item.branchId == value && item.isActive,
    ).firstOrNull;
    setState(() {
      _branchId = value;
      _warehouseId = warehouse?.id;
      _productWorkspace = null;
      _loading = true;
      _error = null;
    });
    try { await _loadProducts(); } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectWarehouse(String? value) async {
    if (value == null || value == _warehouseId) return;
    setState(() {
      _warehouseId = value;
      _productWorkspace = null;
      _loading = true;
      _error = null;
    });
    try { await _loadProducts(); } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object error) {
    final value = error.toString();
    if (value.contains('products_view_permission_required') ||
        value.contains('locations_view_permission_required')) {
      return 'لا تملك صلاحية عرض المنتجات والمخزون في هذا النشاط.';
    }
    if (value.contains('cloud_branch_unavailable')) return 'الفرع غير متاح أو تم إيقافه.';
    if (value.contains('cloud_warehouse_unavailable')) return 'المخزن غير متاح أو لا يتبع الفرع المحدد.';
    if (value.contains('authentication_required') ||
        value.contains('active_business_membership_required')) {
      return 'انتهت صلاحية الجلسة أو لم تعد عضويتك نشطة. سجّل الدخول مجددًا.';
    }
    return 'تعذر تحميل المنتجات السحابية. تحقق من الاتصال والصلاحيات.';
  }

  @override
  Widget build(BuildContext context) {
    final locations = _locationWorkspace;
    final branches = locations?.branches.where((item) => item.isActive).toList() ?? const <CloudBranch>[];
    final warehouses = locations?.warehouses
        .where((item) => item.branchId == _branchId && item.isActive).toList() ?? const <CloudWarehouse>[];
    final products = _productWorkspace?.products ?? const <CloudProduct>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('كتالوج المنتجات السحابي'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loading ? null : _loadLocations,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && locations == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(widget.businessName, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  const Text('عرض سحابي للقراءة فقط. لا يغيّر بيانات SQLite المحلية.'),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('branch-' + (_branchId ?? 'none')),
                    initialValue: _branchId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'الفرع', border: OutlineInputBorder()),
                    items: branches.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
                    onChanged: _loading ? null : _selectBranch,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('warehouse-' + (_warehouseId ?? 'none')),
                    initialValue: _warehouseId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'المخزن', border: OutlineInputBorder()),
                    items: warehouses.map((item) => DropdownMenuItem(value: item.id, child: Text(item.name))).toList(),
                    onChanged: _loading ? null : _selectWarehouse,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(padding: const EdgeInsets.all(14), child: Text(_error!)),
                    )
                  else if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (branches.isEmpty || warehouses.isEmpty)
                    const Card(child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('لا يوجد فرع ومخزن نشطان لعرض المنتجات.'),
                    ))
                  else if (products.isEmpty)
                    const Card(child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('لا توجد منتجات سحابية في هذا النشاط حتى الآن.'),
                    ))
                  else ...[
                    Text('المنتجات (' + products.length.toString() + ')',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ...products.map((product) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.inventory_2_outlined),
                        title: Text(product.name),
                        subtitle: Text([
                          if (product.sku != null && product.sku!.isNotEmpty) 'كود: ' + product.sku!,
                          'إجمالي النشاط: ' + Quantity.format(product.aggregateStockScaled),
                        ].join(' • ')),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(Quantity.format(product.warehouseStockScaled)),
                            const Text('رصيد المخزن', style: TextStyle(fontSize: 11)),
                          ],
                        ),
                      ),
                    )),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'هذه الشاشة لا تنفّذ إضافة أو تعديل أو بيع. لم يتم ربطها بعد بمزامنة البيانات المحلية بين الأجهزة.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
      ),
    );
  }
}
