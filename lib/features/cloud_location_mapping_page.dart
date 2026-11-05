import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_location_mapping_repository.dart';
import '../cloud/cloud_location_repository.dart';
import '../data/local_database.dart';

class CloudLocationMappingPage extends StatefulWidget {
  const CloudLocationMappingPage({
    super.key,
    required this.client,
    required this.businessId,
    required this.businessName,
    required this.workspace,
  });

  final SupabaseClient client;
  final String businessId;
  final String businessName;
  final CloudLocationWorkspace workspace;

  @override
  State<CloudLocationMappingPage> createState() =>
      _CloudLocationMappingPageState();
}

class _CloudLocationMappingPageState extends State<CloudLocationMappingPage> {
  Database? _database;
  CloudLocationMappingRepository? _repository;
  CloudLocationMappingSnapshot? _snapshot;
  final Map<int, String> _branchSelections = {};
  final Map<int, String> _warehouseSelections = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    final database = _database;
    if (database != null) {
      database.close();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final database = _database ??
          await openLocalDatabase(businessId: widget.businessId);
      _database = database;
      _repository ??= CloudLocationMappingRepository(
        database: database,
        remote: SupabaseCloudLocationMappingRemote(widget.client),
        workspace: widget.workspace,
      );
      final snapshot = await _repository!.loadSnapshot(
        businessId: widget.businessId,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _loading = false;
      });
    }
  }

  Future<void> _reloadSnapshot() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final snapshot = await repository.loadSnapshot(
        businessId: widget.businessId,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    }
  }

  Future<bool> _confirmMapping({
    required String localName,
    required String cloudName,
    required String locationType,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('تأكيد ربط $locationType'),
            content: Text(
              'هل تؤكد ربط "$localName" المحلي بـ "$cloudName" السحابي؟\n\n'
              'هذا يحفظ علاقة المعرفات فقط؛ لا ينقل المنتجات أو الأرصدة أو المستندات، ولا يبدأ المزامنة. '
              'لا يمكن تغيير الربط من هذه الشاشة بعد حفظه.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('تأكيد الربط'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _mapBranch(LocalBranchMapping branch) async {
    final selectedId = _branchSelections[branch.id];
    if (selectedId == null) return;
    final cloudBranch = widget.workspace.branches
        .where((item) => item.id == selectedId && item.isActive)
        .firstOrNull;
    if (cloudBranch == null) return;
    final confirmed = await _confirmMapping(
      localName: branch.name,
      cloudName: cloudBranch.name,
      locationType: 'الفرع',
    );
    if (!confirmed || !mounted) return;
    try {
      await _repository!.mapLocalBranch(
        businessId: widget.businessId,
        localBranchId: branch.id,
        cloudBranchId: cloudBranch.id,
        explicitlyConfirmed: true,
      );
      _branchSelections.remove(branch.id);
      await _reloadSnapshot();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ ربط الفرع على هذا الجهاز.')),
        );
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _mapWarehouse(LocalWarehouseMapping warehouse) async {
    final selectedId = _warehouseSelections[warehouse.id];
    if (selectedId == null) return;
    final cloudWarehouse = widget.workspace.warehouses
        .where((item) => item.id == selectedId && item.isActive)
        .firstOrNull;
    if (cloudWarehouse == null) return;
    final confirmed = await _confirmMapping(
      localName: warehouse.name,
      cloudName: cloudWarehouse.name,
      locationType: 'المخزن',
    );
    if (!confirmed || !mounted) return;
    try {
      await _repository!.mapLocalWarehouse(
        businessId: widget.businessId,
        localWarehouseId: warehouse.id,
        cloudWarehouseId: cloudWarehouse.id,
        explicitlyConfirmed: true,
      );
      _warehouseSelections.remove(warehouse.id);
      await _reloadSnapshot();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ ربط المخزن على هذا الجهاز.')),
        );
      }
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_friendlyError(error))),
    );
  }

  String _friendlyError(Object error) {
    final value = error.toString();
    if (value.contains('branches_manage_permission_required')) {
      return 'ربط الفروع يتطلب صلاحية إدارة الفروع.';
    }
    if (value.contains('warehouses_manage_permission_required')) {
      return 'ربط المخازن يتطلب صلاحية إدارة المخازن.';
    }
    if (value.contains('database_business_identity_mismatch')) {
      return 'قاعدة البيانات المفتوحة لا تخص هذا النشاط.';
    }
    if (value.contains('local_location_already_mapped')) {
      return 'هذا الموقع المحلي مرتبط بالفعل بموقع سحابي آخر.';
    }
    if (value.contains('cloud_location_already_mapped')) {
      return 'هذا الموقع السحابي مرتبط بالفعل بموقع محلي آخر.';
    }
    if (value.contains('local_warehouse_branch_mapping_mismatch')) {
      return 'المخزن السحابي المختار لا يتبع الفرع السحابي المرتبط بالفرع المحلي.';
    }
    if (value.contains('cloud_branch_unavailable') ||
        value.contains('cloud_warehouse_unavailable') ||
        value.contains('cloud_warehouse_parent_branch_unavailable')) {
      return 'الموقع السحابي غير متاح أو لم تعد لديك صلاحية عرضه.';
    }
    if (value.contains('local_branch_unavailable') ||
        value.contains('local_warehouse_unavailable') ||
        value.contains('local_warehouse_parent_branch_unavailable')) {
      return 'الموقع المحلي غير نشط أو غير موجود.';
    }
    return 'تعذر حفظ الربط. لم يتم نقل أي بيانات.';
  }

  String _cloudBranchName(String? id) {
    if (id == null) return 'غير مرتبط';
    return widget.workspace.branches
            .where((item) => item.id == id)
            .map((item) => item.name)
            .firstOrNull ??
        'معرف سحابي: $id';
  }

  String _cloudWarehouseName(String? id) {
    if (id == null) return 'غير مرتبط';
    return widget.workspace.warehouses
            .where((item) => item.id == id)
            .map((item) => item.name)
            .firstOrNull ??
        'معرف سحابي: $id';
  }

  Widget _branchCard(LocalBranchMapping branch) {
    final cloudBranches = widget.workspace.branches
        .where((item) => item.isActive)
        .toList(growable: false);
    final selected = _branchSelections[branch.id];
    return Card(
      key: ValueKey('local-branch-card-${branch.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(branch.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('المعرف المحلي: ${branch.id}'),
            if (!branch.isActive)
              const Text('الفرع غير نشط محليًا ولا يمكن ربطه.')
            else if (branch.cloudId != null)
              Text('مرتبط بالفرع السحابي: ${_cloudBranchName(branch.cloudId)}')
            else if (!widget.workspace.canManageBranches)
              const Text('تحتاج إلى صلاحية إدارة الفروع لإجراء الربط.')
            else if (cloudBranches.isEmpty)
              const Text('لا توجد فروع سحابية نشطة متاحة.')
            else ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('branch-map-${branch.id}-${selected ?? 'none'}'),
                initialValue: cloudBranches.any((item) => item.id == selected)
                    ? selected
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'اختر الفرع السحابي المقابل',
                  border: OutlineInputBorder(),
                ),
                items: cloudBranches
                    .map((item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name),
                        ))
                    .toList(),
                onChanged: (value) => setState(() {
                  if (value == null) {
                    _branchSelections.remove(branch.id);
                  } else {
                    _branchSelections[branch.id] = value;
                  }
                }),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(
                  onPressed: selected == null ? null : () => _mapBranch(branch),
                  icon: const Icon(Icons.link),
                  label: const Text('ربط الفرع'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _warehouseCard(
    LocalWarehouseMapping warehouse,
    CloudLocationMappingSnapshot snapshot,
  ) {
    final localBranch = snapshot.branches
        .where((item) => item.id == warehouse.branchId)
        .firstOrNull;
    final cloudBranchId = localBranch?.cloudId;
    final cloudWarehouses = cloudBranchId == null
        ? const <CloudWarehouse>[]
        : widget.workspace.warehouses
            .where((item) =>
                item.isActive && item.branchId == cloudBranchId)
            .toList(growable: false);
    final selected = _warehouseSelections[warehouse.id];
    return Card(
      key: ValueKey('local-warehouse-card-${warehouse.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(warehouse.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('المعرف المحلي: ${warehouse.id}'),
            Text('الفرع المحلي: ${localBranch?.name ?? 'غير معروف'}'),
            if (!warehouse.isActive)
              const Text('المخزن غير نشط محليًا ولا يمكن ربطه.')
            else if (warehouse.cloudId != null)
              Text('مرتبط بالمخزن السحابي: ${_cloudWarehouseName(warehouse.cloudId)}')
            else if (cloudBranchId == null)
              const Text('اربط الفرع المحلي أولًا؛ لا يتم تخمين الفرع المقابل.')
            else if (!widget.workspace.canManageWarehouses)
              const Text('تحتاج إلى صلاحية إدارة المخازن لإجراء الربط.')
            else if (cloudWarehouses.isEmpty)
              const Text('لا توجد مخازن سحابية نشطة تحت الفرع المرتبط.')
            else ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('warehouse-map-${warehouse.id}-${selected ?? 'none'}'),
                initialValue: cloudWarehouses.any((item) => item.id == selected)
                    ? selected
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'اختر المخزن السحابي المقابل',
                  border: OutlineInputBorder(),
                ),
                items: cloudWarehouses
                    .map((item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name),
                        ))
                    .toList(),
                onChanged: (value) => setState(() {
                  if (value == null) {
                    _warehouseSelections.remove(warehouse.id);
                  } else {
                    _warehouseSelections[warehouse.id] = value;
                  }
                }),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(
                  onPressed: selected == null
                      ? null
                      : () => _mapWarehouse(warehouse),
                  icon: const Icon(Icons.link),
                  label: const Text('ربط المخزن'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ربط المواقع المحلية بالسحابة'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && snapshot == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(widget.businessName,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'اختر الربط يدويًا. لا توجد مطابقة تلقائية بالأسماء. '
                        'حفظ الربط لا ينقل المنتجات أو الأرصدة أو المستندات ولا يشغّل المزامنة.',
                      ),
                    ),
                  ),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text('الفروع المحلية',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (snapshot == null || snapshot.branches.isEmpty)
                    const Text('لا توجد فروع محلية في قاعدة بيانات هذا النشاط.')
                  else
                    ...snapshot.branches.map(_branchCard),
                  const SizedBox(height: 20),
                  Text('المخازن المحلية',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (snapshot == null || snapshot.warehouses.isEmpty)
                    const Text('لا توجد مخازن محلية في قاعدة بيانات هذا النشاط.')
                  else
                    ...snapshot.warehouses
                        .map((warehouse) => _warehouseCard(warehouse, snapshot)),
                ],
              ),
      ),
    );
  }
}
