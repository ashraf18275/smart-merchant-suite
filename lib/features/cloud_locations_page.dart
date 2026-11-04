import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cloud/cloud_location_repository.dart';

class CloudLocationsPage extends StatefulWidget {
  const CloudLocationsPage({
    super.key,
    required this.client,
    required this.businessId,
    required this.businessName,
  });

  final SupabaseClient client;
  final String businessId;
  final String businessName;

  @override
  State<CloudLocationsPage> createState() => _CloudLocationsPageState();
}

class _CloudLocationsPageState extends State<CloudLocationsPage> {
  late final CloudLocationRepository _repository =
      CloudLocationRepository(widget.client);
  CloudLocationWorkspace? _workspace;
  String? _branchId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await _repository.load(widget.businessId);
      final branchId = data.branches.any((b) => b.id == _branchId)
          ? _branchId
          : data.branches.where((b) => b.isActive).firstOrNull?.id;
      if (mounted) setState(() { _workspace = data; _branchId = branchId; });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object error) {
    final value = error.toString();
    if (value.contains('locations_view_permission_required')) {
      return 'لا تملك صلاحية عرض الفروع والمخازن.';
    }
    if (value.contains('42501') || value.contains('permission')) {
      return 'ليست لديك الصلاحية اللازمة لتنفيذ هذه العملية.';
    }
    if (value.contains('23514') || value.contains('check_violation')) {
      return 'لا يمكن إيقاف موقع يحتوي على مخزون أو وردية مفتوحة، أو آخر موقع نشط.';
    }
    return 'تعذر تنفيذ العملية. تحقق من الاتصال والصلاحيات.';
  }

  Future<String?> _askName(String title) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'الاسم'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }

  Future<void> _createBranch() async {
    final name = await _askName('إضافة فرع');
    if (name == null) return;
    try {
      await _repository.createBranch(businessId: widget.businessId, name: name);
      await _reload();
      if (mounted) _notice('تم إنشاء الفرع والمخزن الرئيسي التابع له.');
    } catch (error) { if (mounted) _notice(_friendlyError(error)); }
  }

  Future<void> _createWarehouse() async {
    final branchId = _branchId;
    if (branchId == null) return;
    final name = await _askName('إضافة مخزن');
    if (name == null) return;
    try {
      await _repository.createWarehouse(
        businessId: widget.businessId,
        branchId: branchId,
        name: name,
      );
      await _reload();
      if (mounted) _notice('تم إنشاء المخزن.');
    } catch (error) { if (mounted) _notice(_friendlyError(error)); }
  }

  Future<void> _toggleBranch(CloudBranch branch) async {
    try {
      await _repository.setBranchActive(
        businessId: widget.businessId,
        branchId: branch.id,
        isActive: !branch.isActive,
      );
      await _reload();
    } catch (error) { if (mounted) _notice(_friendlyError(error)); }
  }

  Future<void> _toggleWarehouse(CloudWarehouse warehouse) async {
    try {
      await _repository.setWarehouseActive(
        businessId: widget.businessId,
        warehouseId: warehouse.id,
        isActive: !warehouse.isActive,
      );
      await _reload();
    } catch (error) { if (mounted) _notice(_friendlyError(error)); }
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final data = _workspace;
    final branch = data?.branches.where((b) => b.id == _branchId).firstOrNull;
    final warehouses = data?.warehouses.where((w) => w.branchId == _branchId).toList() ??
        const <CloudWarehouse>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('الفروع والمخازن السحابية'),
        actions: [
          IconButton(onPressed: _loading ? null : _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: data?.canManageBranches == true
          ? FloatingActionButton.extended(
              onPressed: _loading ? null : _createBranch,
              icon: const Icon(Icons.add_business),
              label: const Text('إضافة فرع'),
            )
          : null,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ))
                : data == null
                    ? const Center(child: Text('لا توجد بيانات.'))
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                        children: [
                          Text(widget.businessName, style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            value: _branchId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'الفرع',
                              border: OutlineInputBorder(),
                            ),
                            items: data.branches.map((b) => DropdownMenuItem(
                              value: b.id,
                              child: Text('${b.name}${b.isActive ? '' : ' — متوقف'}'),
                            )).toList(),
                            onChanged: (value) => setState(() => _branchId = value),
                          ),
                          if (branch != null && data.canManageBranches)
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton(
                                onPressed: () => _toggleBranch(branch),
                                child: Text(branch.isActive ? 'إيقاف الفرع' : 'تفعيل الفرع'),
                              ),
                            ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(child: Text('المخازن', style: Theme.of(context).textTheme.titleMedium)),
                              if (data.canManageWarehouses && branch?.isActive == true)
                                TextButton.icon(
                                  onPressed: _createWarehouse,
                                  icon: const Icon(Icons.add),
                                  label: const Text('إضافة مخزن'),
                                ),
                            ],
                          ),
                          if (warehouses.isEmpty)
                            const Card(child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('لا توجد مخازن لهذا الفرع.'),
                            ))
                          else
                            ...warehouses.map((w) => Card(
                              child: ListTile(
                                leading: const Icon(Icons.warehouse_outlined),
                                title: Text(w.name),
                                subtitle: Text(w.isActive ? 'نشط' : 'متوقف'),
                                trailing: data.canManageWarehouses
                                    ? IconButton(
                                        tooltip: w.isActive ? 'إيقاف المخزن' : 'تفعيل المخزن',
                                        onPressed: () => _toggleWarehouse(w),
                                        icon: Icon(w.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline),
                                      )
                                    : null,
                              ),
                            )),
                          const SizedBox(height: 16),
                          const Text(
                            'هذه بيانات المواقع السحابية فقط. شاشات البيع والمخزون الحالية لا تزال تعمل محليًا حتى اكتمال المزامنة.',
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
      ),
    );
  }
}
