import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/quantity.dart';
import '../data/product_repository.dart';
import '../data/purchase_repository.dart';
import '../data/warehouse_repository.dart';
import '../domain/product.dart';
import '../domain/warehouse.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({
    super.key,
    required this.purchases,
    required this.products,
    required this.warehouses,
  });

  final PurchaseRepository purchases;
  final ProductRepository products;
  final WarehouseRepository warehouses;

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchaseLineDraft {
  int? productId;
  final quantity = TextEditingController();
  final unitCost = TextEditingController();

  void dispose() {
    quantity.dispose();
    unitCost.dispose();
  }
}

class _PurchasesPageState extends State<PurchasesPage> {
  List<Map<String, Object?>> _suppliers = [];
  List<Product> _products = [];
  List<Warehouse> _warehouses = [];
  int? _supplierId;
  int? _warehouseId;
  final _paid = TextEditingController();
  final List<_PurchaseLineDraft> _lines = [_PurchaseLineDraft()];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _paid.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  String _money(int minor) =>
      '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')} ج.م';

  int? _parseMoney(String value) {
    final match = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(value.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  }

  Future<void> _load() async {
    try {
      // Keep reads sequential: the local SQLite connection is shared by
      // these repositories, and serial reads avoid overlapping operations
      // on desktop and in the no-isolate test backend.
      final suppliers = await widget.purchases.suppliers();
      final products = await widget.products.all();
      final warehouses = await widget.warehouses.warehouses();
      if (!mounted) return;
      final defaultWarehouse = warehouses.where((w) =>
          w.name == 'المخزن الرئيسي' && w.branchName == 'الفرع الرئيسي');
      setState(() {
        _suppliers = suppliers;
        _products = products;
        _warehouses = warehouses;
        _supplierId = suppliers.any((s) => s['id'] == _supplierId)
            ? _supplierId
            : (suppliers.isEmpty ? null : suppliers.first['id'] as int);
        _warehouseId = warehouses.any((w) => w.id == _warehouseId)
            ? _warehouseId
            : (defaultWarehouse.isNotEmpty
                ? defaultWarehouse.first.id
                : (warehouses.isEmpty ? null : warehouses.first.id));
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = appErrorMessage(error,
            fallback: 'تعذر تحميل بيانات المشتريات.',
            operation: 'purchases.load');
      });
    }
  }

  Future<void> _addSupplier() async {
    final draft = await showDialog<_SupplierDraft>(
      context: context,
      builder: (ctx) => const _AddSupplierDialog(),
    );
    if (draft == null) return;
    try {
      final id = await widget.purchases.addSupplier(
        name: draft.name, phone: draft.phone, address: draft.address);
      await _load();
      if (mounted) setState(() => _supplierId = id);
    } catch (error) {
      _showError(error, 'تعذر حفظ المورد.');
    }
  }

  Product? _product(int? id) {
    for (final item in _products) {
      if (item.id == id) return item;
    }
    return null;
  }

  int? _lineTotal(_PurchaseLineDraft line) {
    final product = _product(line.productId);
    if (product == null) return null;
    final quantity = Quantity.parse(
      line.quantity.text, allowsFraction: product.unitAllowsFraction);
    final cost = _parseMoney(line.unitCost.text);
    if (quantity == null || quantity <= 0 || cost == null || cost <= 0) {
      return null;
    }
    return Quantity.lineTotalMinor(
      unitPriceMinor: cost, quantityScaled: quantity);
  }

  int get _total => _lines.fold<int>(0,
      (sum, line) => sum + (_lineTotal(line) ?? 0));

  Future<void> _savePurchase() async {
    if (_supplierId == null || _warehouseId == null) {
      _showMessage('أضف موردًا واختر مخزنًا نشطًا أولًا.');
      return;
    }
    final prepared = <PurchaseLineInput>[];
    final seen = <int>{};
    for (final line in _lines) {
      final product = _product(line.productId);
      if (product == null) {
        _showMessage('اختر منتجًا لكل بند.');
        return;
      }
      final quantity = Quantity.parse(
          line.quantity.text, allowsFraction: product.unitAllowsFraction);
      final cost = _parseMoney(line.unitCost.text);
      if (quantity == null || quantity <= 0 || cost == null || cost <= 0) {
        _showMessage('راجع الكمية وتكلفة الوحدة في كل بند.');
        return;
      }
      if (!seen.add(product.id!)) {
        _showMessage('لا تكرر المنتج في الفاتورة نفسها.');
        return;
      }
      prepared.add(PurchaseLineInput(
          productId: product.id!, quantity: quantity, unitCostMinor: cost));
    }
    final paid = _parseMoney(_paid.text.isEmpty ? '0' : _paid.text);
    if (paid == null || paid < 0 || paid > _total) {
      _showMessage('راجع المبلغ المدفوع؛ يجب ألا يتجاوز إجمالي الفاتورة.');
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await widget.purchases.createPurchase(
        supplierId: _supplierId!,
        warehouseId: _warehouseId!,
        items: prepared,
        paidMinor: paid,
      );
      for (final line in _lines) {
        line.dispose();
      }
      _lines
        ..clear()
        ..add(_PurchaseLineDraft());
      _paid.clear();
      await _load();
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم استلام المشتريات وحفظ الفاتورة رقم $id')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _saving = false);
      _showError(error, 'لم يتم حفظ فاتورة المشتريات.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)));
  }

  void _showError(Object error, String fallback) {
    if (!mounted) return;
    _showMessage(appErrorMessage(error,
        fallback: fallback, operation: 'purchases.create'));
  }

  Widget _lineCard(_PurchaseLineDraft line, int index) {
    final chosen = _product(line.productId);
    final selectedIds = _lines
        .where((other) => other != line)
        .map((other) => other.productId)
        .whereType<int>()
        .toSet();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('الصنف ${index + 1}',
                style: const TextStyle(fontWeight: FontWeight.w700))),
            if (_lines.length > 1)
              IconButton(
                tooltip: 'حذف البند',
                onPressed: () => setState(() {
                  _lines.remove(line);
                  line.dispose();
                }),
                icon: const Icon(Icons.delete_outline),
              ),
          ]),
          DropdownButtonFormField<int>(
            initialValue: line.productId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'اختر المنتج'),
            items: [
              for (final product in _products.where((p) =>
                  !selectedIds.contains(p.id) || p.id == line.productId))
                DropdownMenuItem(
                  value: product.id,
                  child: Text(product.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() {
              line.productId = value;
              line.quantity.clear();
              line.unitCost.clear();
            }),
          ),
          if (chosen != null) ...[
            const SizedBox(height: 8),
            Text('التكلفة الحالية: ${_money(chosen.costMinor)} • سعر البيع المقترح: ${_money(chosen.priceMinor)}',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(
              controller: line.quantity,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'الكمية'),
              onChanged: (_) => setState(() {}),
            )),
            const SizedBox(width: 10),
            Expanded(child: TextField(
              controller: line.unitCost,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'تكلفة الوحدة (ج.م)'),
              onChanged: (_) => setState(() {}),
            )),
          ]),
          if (_lineTotal(line) != null)
            Align(alignment: Alignment.centerLeft,
              child: Text('إجمالي البند: ${_money(_lineTotal(line)!)}',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المشتريات واستلام المخزون')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, textAlign: TextAlign.center),
                OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
              ]))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(children: [
                    Expanded(child: DropdownButtonFormField<int>(
                      initialValue: _supplierId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'المورد'),
                      items: [for (final s in _suppliers)
                        DropdownMenuItem(value: s['id'] as int,
                          child: Text(s['name'] as String,
                              overflow: TextOverflow.ellipsis))],
                      onChanged: (value) => setState(() => _supplierId = value),
                    )),
                    IconButton(
                      tooltip: 'إضافة مورد',
                      onPressed: _saving ? null : _addSupplier,
                      icon: const Icon(Icons.person_add_alt_1),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _warehouseId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'مخزن الاستلام'),
                    items: [for (final w in _warehouses)
                      DropdownMenuItem(value: w.id,
                        child: Text('${w.branchName} — ${w.name}',
                            overflow: TextOverflow.ellipsis))],
                    onChanged: (value) => setState(() => _warehouseId = value),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    const Expanded(child: Text('أصناف الفاتورة',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                    TextButton.icon(
                      onPressed: _saving ? null : () =>
                          setState(() => _lines.add(_PurchaseLineDraft())),
                      icon: const Icon(Icons.add),
                      label: const Text('إضافة صنف'),
                    ),
                  ]),
                  if (_products.isEmpty)
                    const Card(child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('لا توجد منتجات نشطة. أضف المنتجات من قسم المنتجات أولًا.'),
                    )),
                  for (var i = 0; i < _lines.length; i++)
                    _lineCard(_lines[i], i),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _paid,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'المبلغ المدفوع الآن (ج.م)',
                      hintText: 'اتركه فارغًا إذا لم تدفع شيئًا',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      const Expanded(child: Text('إجمالي المشتريات',
                          style: TextStyle(fontWeight: FontWeight.w700))),
                      Text(_money(_total),
                          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                    ]),
                  )),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _saving || _products.isEmpty || _warehouses.isEmpty
                        ? null : _savePurchase,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.inventory),
                    label: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ الفاتورة واستلام المخزون'),
                  ),
                ],
              ),
  );
}


class _SupplierDraft {
  const _SupplierDraft({
    required this.name,
    required this.phone,
    required this.address,
  });
  final String name;
  final String phone;
  final String address;
}

class _AddSupplierDialog extends StatefulWidget {
  const _AddSupplierDialog();

  @override
  State<_AddSupplierDialog> createState() => _AddSupplierDialogState();
}

class _AddSupplierDialogState extends State<_AddSupplierDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إضافة مورد'),
    content: Form(
      key: _formKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم المورد *'),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'اسم المورد مطلوب'
              : null,
        ),
        TextField(controller: _phone,
          decoration: const InputDecoration(labelText: 'الهاتف')),
        TextField(controller: _address,
          decoration: const InputDecoration(labelText: 'العنوان')),
      ]),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(context, _SupplierDraft(
              name: _name.text,
              phone: _phone.text,
              address: _address.text,
            ));
          }
        },
        child: const Text('حفظ المورد'),
      ),
    ],
  );
}
