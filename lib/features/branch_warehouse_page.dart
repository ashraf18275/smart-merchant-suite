import 'package:flutter/material.dart';

import '../application/ports/branch_warehouse_store.dart';
import '../core/app_error.dart';
import '../domain/branch.dart';
import '../domain/warehouse.dart';
import '../domain/warehouse_stock.dart';
import '../core/quantity.dart';

class BranchWarehousePage extends StatefulWidget {
  const BranchWarehousePage({super.key, required this.store});
  final BranchWarehouseStore store;

  @override
  State<BranchWarehousePage> createState() => _BranchWarehousePageState();
}

class _BranchWarehousePageState extends State<BranchWarehousePage> {
  List<Branch> _branches = [];
  List<Warehouse> _warehouses = [];
  List<WarehouseStock> _stock = [];
  int? _branchId;
  int? _warehouseId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final branches = await widget.store.branches(includeInactive: true);
      final warehouses = await widget.store.warehouses(includeInactive: true);
      final activeBranches = branches.where((x) => x.isActive).toList();
      final defaultBranch = activeBranches.where((x) => x.name == 'الفرع الرئيسي');
      final branchId = activeBranches.any((x) => x.id == _branchId)
          ? _branchId
          : (defaultBranch.isNotEmpty
              ? defaultBranch.first.id
              : (activeBranches.isEmpty ? null : activeBranches.first.id));
      final activeWarehouses = warehouses.where((x) => x.isActive && x.branchId == branchId).toList();
      final defaultWarehouse = activeWarehouses.where((x) => x.name == 'المخزن الرئيسي');
      final warehouseId = activeWarehouses.any((x) => x.id == _warehouseId)
          ? _warehouseId
          : (defaultWarehouse.isNotEmpty
              ? defaultWarehouse.first.id
              : (activeWarehouses.isEmpty ? null : activeWarehouses.first.id));
      final stock = warehouseId == null
          ? <WarehouseStock>[]
          : await widget.store.stock(warehouseId: warehouseId);
      if (!mounted) return;
      setState(() {
        _branches = branches;
        _warehouses = warehouses;
        _branchId = branchId;
        _warehouseId = warehouseId;
        _stock = stock;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = appErrorMessage(error, fallback: 'تعذر تحميل بيانات الفروع والمخازن.', operation: 'warehouse.load');
      });
    }
  }

  String _quantity(int scaled) => Quantity.format(scaled);

  void _showError(Object error, String fallback) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(appErrorMessage(error, fallback: fallback, operation: 'warehouse.action'))),
    );
  }

  Future<void> _branchDialog([Branch? branch]) async {
    final name = TextEditingController(text: branch?.name ?? '');
    final address = TextEditingController(text: branch?.address ?? '');
    final phone = TextEditingController(text: branch?.phone ?? '');
    final key = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(branch == null ? 'إضافة فرع' : 'تعديل الفرع'),
        content: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم الفرع *'),
              validator: (v) => v == null || v.trim().isEmpty ? 'اكتب اسم الفرع' : null),
            TextFormField(controller: address, decoration: const InputDecoration(labelText: 'العنوان')),
            TextFormField(controller: phone, decoration: const InputDecoration(labelText: 'الهاتف')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('حفظ')),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (saved == true) {
      try {
        if (branch == null) {
          await widget.store.addBranch(name: name.text, address: address.text, phone: phone.text);
        } else {
          await widget.store.updateBranch(id: branch.id, name: name.text, address: address.text, phone: phone.text);
        }
        await _load();
      } catch (e) { _showError(e, 'تعذر حفظ الفرع.'); }
    }
    name.dispose();
    address.dispose();
    phone.dispose();
  }

  Future<void> _warehouseDialog([Warehouse? warehouse]) async {
    final name = TextEditingController(text: warehouse?.name ?? '');
    final key = GlobalKey<FormState>();
    int? branchId = warehouse?.branchId ?? _branchId;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(warehouse == null ? 'إضافة مخزن' : 'تعديل المخزن'),
          content: Form(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<int>(
                initialValue: branchId,
                decoration: const InputDecoration(labelText: 'الفرع'),
                items: [
                  for (final b in _branches.where((x) => x.isActive || x.id == branchId))
                    DropdownMenuItem(value: b.id, child: Text(b.name)),
                ],
                onChanged: warehouse == null ? (v) => setDialogState(() => branchId = v) : null,
                validator: (v) => v == null ? 'اختر الفرع' : null,
              ),
              TextFormField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم المخزن *'),
                validator: (v) => v == null || v.trim().isEmpty ? 'اكتب اسم المخزن' : null),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('حفظ')),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (saved == true && branchId != null) {
      try {
        if (warehouse == null) {
          await widget.store.addWarehouse(branchId: branchId!, name: name.text);
        } else {
          await widget.store.updateWarehouse(id: warehouse.id, name: name.text);
        }
        _branchId = branchId;
        await _load();
      } catch (e) { _showError(e, 'تعذر حفظ المخزن.'); }
    }
    name.dispose();
  }

  Future<void> _toggleBranch(Branch item) async {
    try {
      await widget.store.setBranchActive(id: item.id, isActive: !item.isActive);
      await _load();
    } catch (e) { _showError(e, 'تعذر تغيير حالة الفرع.'); }
  }

  Future<void> _toggleWarehouse(Warehouse item) async {
    try {
      await widget.store.setWarehouseActive(id: item.id, isActive: !item.isActive);
      await _load();
    } catch (e) { _showError(e, 'تعذر تغيير حالة المخزن.'); }
  }

  Future<void> _transfer(WarehouseStock item) async {
    final source = _warehouseId;
    final targets = _warehouses.where((x) => x.isActive && x.id != source).toList();
    if (source == null || targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أضف مخزنًا نشطًا آخر لإجراء التحويل.')));
      return;
    }
    final quantity = TextEditingController(text: '1');
    final reason = TextEditingController(text: 'تحويل بين المخازن');
    final key = GlobalKey<FormState>();
    int targetId = targets.first.id;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('تحويل ' + item.productName),
          content: Form(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<int>(
                initialValue: targetId,
                decoration: const InputDecoration(labelText: 'إلى المخزن'),
                items: [for (final w in targets) DropdownMenuItem(value: w.id, child: Text(w.branchName + ' — ' + w.name))],
                onChanged: (v) { if (v != null) setDialogState(() => targetId = v); },
              ),
              TextFormField(controller: quantity, keyboardType: TextInputType.number,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'المتاح: ' + _quantity(item.quantity) + ' ' + item.unitName),
                validator: (v) {
                  final n = Quantity.parse(v ?? '', allowsFraction: item.allowsFraction);
                  if (n == null || n <= 0) return 'أدخل كمية صحيحة حسب وحدة القياس';
                  if (n > item.quantity) return 'الكمية أكبر من المتاح';
                  return null;
                }),
              TextFormField(controller: reason, decoration: const InputDecoration(labelText: 'سبب التحويل')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('تنفيذ التحويل')),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (saved == true) {
      try {
        await widget.store.transferStock(
          productId: item.productId,
          fromWarehouseId: source,
          toWarehouseId: targetId,
          quantity: Quantity.parse(quantity.text, allowsFraction: item.allowsFraction)!,
          reason: reason.text,
        );
        await _load();
      } catch (e) { _showError(e, 'تعذر تحويل المخزون.'); }
    }
    quantity.dispose();
    reason.dispose();
  }

  Future<void> _adjust(WarehouseStock item) async {
    final delta = TextEditingController();
    final reason = TextEditingController();
    final key = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تسوية مخزون: ' + item.productName),
        content: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('الرصيد الحالي: ' + _quantity(item.quantity) + ' ' + item.unitName),
            TextFormField(controller: delta, keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: const InputDecoration(labelText: 'فرق الكمية (+ إضافة / - خصم)'),
              validator: (v) {
                final n = Quantity.parse(v ?? '', allowsFraction: item.allowsFraction, allowNegative: true);
                if (n == null || n == 0) return 'أدخل فرقًا صحيحًا غير صفر حسب وحدة القياس';
                if (item.quantity + n < 0) return 'الرصيد لا يسمح بهذا الخصم';
                return null;
              }),
            TextFormField(controller: reason, decoration: const InputDecoration(labelText: 'سبب التسوية'),
              validator: (v) => v == null || v.trim().isEmpty ? 'سبب التسوية مطلوب' : null),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('حفظ التسوية')),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (saved == true && _warehouseId != null) {
      try {
        await widget.store.adjustStock(
          warehouseId: _warehouseId!,
          productId: item.productId,
          quantityDelta: Quantity.parse(delta.text, allowsFraction: item.allowsFraction, allowNegative: true)!,
          reason: reason.text,
        );
        await _load();
      } catch (e) { _showError(e, 'تعذر تسوية المخزون.'); }
    }
    delta.dispose();
    reason.dispose();
  }

  Widget _branchList() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final item in _branches)
        Card(child: ListTile(
          title: Text(item.name),
          subtitle: Text((item.address ?? 'بدون عنوان') + ' • ' + (item.phone ?? 'بدون هاتف') + ' • ' + (item.isActive ? 'نشط' : 'موقوف')),
          trailing: Wrap(children: [
            IconButton(tooltip: 'تعديل الفرع', onPressed: () => _branchDialog(item), icon: const Icon(Icons.edit_outlined)),
            IconButton(tooltip: item.isActive ? 'إيقاف الفرع' : 'تفعيل الفرع', onPressed: () => _toggleBranch(item), icon: Icon(item.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline)),
          ]),
        )),
      if (_branches.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد فروع.')),
    ],
  );

  Widget _warehouseList() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      DropdownButtonFormField<int>(
        initialValue: _branchId,
        decoration: const InputDecoration(labelText: 'تصفية حسب الفرع'),
        items: [for (final b in _branches.where((x) => x.isActive)) DropdownMenuItem(value: b.id, child: Text(b.name))],
        onChanged: (v) async {
          _branchId = v;
          _warehouseId = null;
          await _load();
        },
      ),
      const SizedBox(height: 12),
      for (final item in _warehouses.where((x) => x.branchId == _branchId))
        Card(child: ListTile(
          title: Text(item.name),
          subtitle: Text(item.branchName + ' • ' + (item.isActive ? 'نشط' : 'موقوف')),
          trailing: Wrap(children: [
            IconButton(tooltip: 'تعديل المخزن', onPressed: () => _warehouseDialog(item), icon: const Icon(Icons.edit_outlined)),
            IconButton(tooltip: item.isActive ? 'إيقاف المخزن' : 'تفعيل المخزن', onPressed: () => _toggleWarehouse(item), icon: Icon(item.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline)),
          ]),
        )),
      if (_warehouses.where((x) => x.branchId == _branchId).isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد مخازن في هذا الفرع.')),
    ],
  );

  Widget _stockList() => Column(children: [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: DropdownButtonFormField<int>(
        initialValue: _warehouseId,
        decoration: const InputDecoration(labelText: 'المخزن المحدد'),
        items: [for (final w in _warehouses.where((x) => x.isActive)) DropdownMenuItem(value: w.id, child: Text(w.branchName + ' — ' + w.name))],
        onChanged: (v) async {
          _warehouseId = v;
          final selected = _warehouses.where((x) => x.id == v);
          if (selected.isNotEmpty) _branchId = selected.first.branchId;
          await _load();
        },
      ),
    ),
    Expanded(
      child: _stock.isEmpty
          ? const Center(child: Text('لا توجد منتجات لعرضها في هذا المخزن.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _stock.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = _stock[index];
                return Card(child: ListTile(
                  title: Text(item.productName),
                  subtitle: Text('الرصيد: ' + item.quantity.toString() + ' ' + item.unitName + (item.sku == null ? '' : ' • ' + item.sku!)),
                  trailing: Wrap(children: [
                    IconButton(tooltip: 'تسوية المخزون', onPressed: () => _adjust(item), icon: const Icon(Icons.tune)),
                    IconButton(tooltip: 'تحويل إلى مخزن آخر', onPressed: () => _transfer(item), icon: const Icon(Icons.swap_horiz)),
                  ]),
                ));
              },
            ),
    ),
  ]);

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('الفروع والمخازن'),
        bottom: const TabBar(tabs: [
          Tab(text: 'الفروع', icon: Icon(Icons.store_outlined)),
          Tab(text: 'المخازن', icon: Icon(Icons.warehouse_outlined)),
          Tab(text: 'أرصدة المخزون', icon: Icon(Icons.inventory_2_outlined)),
        ]),
      ),
      floatingActionButton: Builder(
        builder: (context) => FloatingActionButton.extended(
          onPressed: _loading ? null : () {
            switch (DefaultTabController.of(context).index) {
              case 0: _branchDialog(); break;
              case 1: _warehouseDialog(); break;
              default: ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('استخدم أزرار التسوية والتحويل بجوار كل منتج.')));
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('إضافة'),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                ]))
              : TabBarView(children: [_branchList(), _warehouseList(), _stockList()]),
    ),
  );
}
