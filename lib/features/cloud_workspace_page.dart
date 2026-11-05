import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_auth_repository.dart';
import '../cloud/cloud_business.dart';
import '../cloud/cloud_location_repository.dart';
import '../cloud/cloud_workspace_context.dart';
import '../data/local_database.dart';
import 'home_dashboard.dart' as local_dashboard;
import 'cloud_locations_page.dart';
import 'cloud_location_mapping_page.dart';
import 'cloud_members_page.dart';
import 'cloud_products_page.dart';

class CloudWorkspacePage extends StatefulWidget {
  const CloudWorkspacePage({
    super.key,
    required this.client,
    required this.business,
  });

  final SupabaseClient client;
  final CloudBusiness business;

  @override
  State<CloudWorkspacePage> createState() => _CloudWorkspacePageState();
}

class _CloudWorkspacePageState extends State<CloudWorkspacePage> {
  late final CloudLocationRepository _locations =
      CloudLocationRepository(widget.client);
  late final CloudAuthRepository _auth = CloudAuthRepository(widget.client);

  Database? _database;
  CloudWorkspaceContextRepository? _selectionStore;
  CloudLocationWorkspace? _workspace;
  CloudWorkspaceContext? _selection;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    final database = _database;
    if (database != null) unawaited(database.close());
    super.dispose();
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final user = _auth.currentUser;
      if (user == null) throw StateError('authentication_required');
      final database = _database ?? await openLocalDatabase();
      _database = database;
      final store =
          _selectionStore ?? CloudWorkspaceContextRepository(database);
      _selectionStore = store;

      final data = await _locations.load(widget.business.id);
      final saved = await store.load(
        userId: user.id,
        businessId: widget.business.id,
      );
      final resolved = CloudWorkspaceContext.resolve(
        businessId: widget.business.id,
        branches: data.branches,
        warehouses: data.warehouses,
        previous: _selection ?? saved,
      );

      if (resolved != null && resolved != saved) {
        await store.save(userId: user.id, selection: resolved);
      }
      if (!mounted) return;
      setState(() {
        _workspace = data;
        _selection = resolved;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _persistSelection(CloudWorkspaceContext selection) async {
    final user = _auth.currentUser;
    if (user == null) {
      await _reload();
      return;
    }

    var data = _workspace;
    if (data == null ||
        !selection.isValidFor(
          expectedBusinessId: widget.business.id,
          branches: data.branches,
          warehouses: data.warehouses,
        )) {
      try {
        data = await _locations.load(widget.business.id);
      } catch (_) {
        await _reload();
        return;
      }
    }

    if (!selection.isValidFor(
      expectedBusinessId: widget.business.id,
      branches: data.branches,
      warehouses: data.warehouses,
    )) {
      if (mounted) setState(() => _workspace = data);
      await _reload();
      return;
    }

    try {
      await _selectionStore?.save(userId: user.id, selection: selection);
      if (mounted) {
        setState(() {
          _workspace = data;
          _selection = selection;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    }
  }

  Future<void> _selectBranch(String? branchId) async {
    if (branchId == null || _workspace == null) return;
    final next = CloudWorkspaceContext.resolve(
      businessId: widget.business.id,
      branches: _workspace!.branches,
      warehouses: _workspace!.warehouses,
      previous: CloudWorkspaceContext(
        businessId: widget.business.id,
        branchId: branchId,
        warehouseId: null,
      ),
    );
    if (next != null) await _persistSelection(next);
  }

  Future<void> _selectWarehouse(String? warehouseId) async {
    if (warehouseId == null || _workspace == null) return;
    final warehouse = _workspace!.warehouses.where(
      (item) => item.id == warehouseId && item.isActive,
    ).firstOrNull;
    if (warehouse == null) return;
    await _persistSelection(CloudWorkspaceContext(
      businessId: widget.business.id,
      branchId: warehouse.branchId,
      warehouseId: warehouse.id,
    ));
  }

  Future<void> _openProducts() async {
    final selection = _selection;
    if (selection == null || selection.warehouseId == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CloudProductsPage(
        client: widget.client,
        businessId: widget.business.id,
        businessName: widget.business.name,
        initialBranchId: selection.branchId,
        initialWarehouseId: selection.warehouseId,
        onContextChanged: _persistSelection,
      ),
    ));
    if (mounted) await _reload();
  }

  Future<void> _openLocations() async {
    final selection = _selection;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CloudLocationsPage(
        client: widget.client,
        businessId: widget.business.id,
        businessName: widget.business.name,
        initialBranchId: selection?.branchId,
        initialWarehouseId: selection?.warehouseId,
        onContextChanged: _persistSelection,
      ),
    ));
    if (mounted) await _reload();
  }

  Future<void> _openLocationMappings() async {
    final workspace = _workspace;
    if (workspace == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CloudLocationMappingPage(
        client: widget.client,
        businessId: widget.business.id,
        businessName: widget.business.name,
        workspace: workspace,
      ),
    ));
    if (mounted) await _reload();
  }

  Future<void> _openLocalBusinessData() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => local_dashboard.HomeDashboard(
        businessId: widget.business.id,
      ),
    ));
  }

  Future<void> _openMembers() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CloudMembersPage(
        client: widget.client,
        businessId: widget.business.id,
        businessName: widget.business.name,
      ),
    ));
  }

  String _friendlyError(Object error) {
    final value = error.toString();
    if (value.contains('authentication_required')) {
      return 'انتهت جلسة الدخول. سجّل الدخول مرة أخرى.';
    }
    if (value.contains('locations_view_permission_required') ||
        value.contains('permission denied') ||
        value.contains('42501')) {
      return 'لا تملك صلاحية عرض سياق الفروع والمخازن لهذا النشاط.';
    }
    return 'تعذر تحميل مساحة النشاط. تحقق من الاتصال والصلاحيات.';
  }

  @override
  Widget build(BuildContext context) {
    final data = _workspace;
    final selection = _selection;
    final branches = data?.branches.where((item) => item.isActive).toList() ??
        const <CloudBranch>[];
    final warehouses = data?.warehouses
            .where((item) =>
                item.isActive && item.branchId == selection?.branchId)
            .toList() ??
        const <CloudWarehouse>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('مساحة النشاط'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && data == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    widget.business.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text('حدد الفرع والمخزن المستخدمين في شاشات السحابة.'),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(_error!),
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('cloud-branch-${selection?.branchId ?? 'none'}'),
                    initialValue: branches.any((item) => item.id == selection?.branchId)
                        ? selection?.branchId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'الفرع',
                      border: OutlineInputBorder(),
                    ),
                    items: branches
                        .map((item) => DropdownMenuItem(
                              value: item.id,
                              child: Text(item.name),
                            ))
                        .toList(),
                    onChanged: _loading ? null : _selectBranch,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('cloud-warehouse-${selection?.warehouseId ?? 'none'}'),
                    initialValue: warehouses.any((item) => item.id == selection?.warehouseId)
                        ? selection?.warehouseId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'المخزن',
                      border: OutlineInputBorder(),
                    ),
                    items: warehouses
                        .map((item) => DropdownMenuItem(
                              value: item.id,
                              child: Text(item.name),
                            ))
                        .toList(),
                    onChanged: _loading ? null : _selectWarehouse,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _loading || selection?.warehouseId == null
                        ? null
                        : _openProducts,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('المنتجات والمخزون السحابي'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _openLocations,
                    icon: const Icon(Icons.warehouse_outlined),
                    label: const Text('إدارة الفروع والمخازن'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _loading || data == null ? null : _openLocationMappings,
                    icon: const Icon(Icons.link_outlined),
                    label: const Text('ربط الفروع والمخازن المحلية بالسحابة'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _openMembers,
                    icon: const Icon(Icons.people_outline),
                    label: const Text('المستخدمون والصلاحيات'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _openLocalBusinessData,
                    icon: const Icon(Icons.storefront_outlined),
                    label: const Text('فتح بيانات هذا النشاط على الجهاز'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'تُفتح بيانات هذا النشاط في قاعدة SQLite مستقلة على هذا الجهاز. لا تُنقل إليها بياناتك المحلية القديمة تلقائيًا، ولا تبدأ المزامنة.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (data != null &&
                      !data.canManageBranches &&
                      !data.canManageWarehouses)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'يمكنك عرض المواقع المتاحة فقط؛ إدارة الفروع والمخازن تتطلب صلاحيات منفصلة.',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
