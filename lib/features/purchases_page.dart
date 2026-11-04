import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/quantity.dart';
import '../data/product_repository.dart';
import '../data/purchase_repository.dart';
import '../data/warehouse_repository.dart';
import '../domain/product.dart';
import '../domain/warehouse.dart';
import '../domain/payment_method.dart';

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
  String _paymentMethod = PaymentMethod.cash;
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
        paymentMethod: _paymentMethod,
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

  Future<void> _createSupplierReturn() async {
    final returnId = await showDialog<int>(
      context: context,
      builder: (_) => _SupplierReturnDialog(repository: widget.purchases),
    );
    if (returnId == null || !mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم حفظ مرتجع المورد رقم $returnId وتحديث المخزون والحساب')),
    );
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
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _createSupplierReturn,
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text('إنشاء مرتجع مورد'),
                  ),
                  const SizedBox(height: 12),
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
                  DropdownButtonFormField<String>(
                    initialValue: _paymentMethod,
                    decoration: const InputDecoration(labelText: 'طريقة سداد المبلغ المدفوع'),
                    items: PaymentMethod.labels.entries.map((entry) =>
                      DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
                    onChanged: _saving ? null : (value) {
                      if (value != null) setState(() => _paymentMethod = value);
                    },
                  ),
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


class _SupplierReturnLineDraft {
  _SupplierReturnLineDraft(this.data);
  final Map<String, Object?> data;
  final quantity = TextEditingController();

  void dispose() => quantity.dispose();
}

class _SupplierReturnDialog extends StatefulWidget {
  const _SupplierReturnDialog({required this.repository});
  final PurchaseRepository repository;

  @override
  State<_SupplierReturnDialog> createState() => _SupplierReturnDialogState();
}

class _SupplierReturnDialogState extends State<_SupplierReturnDialog> {
  final _reason = TextEditingController();
  final _refundAmount = TextEditingController(text: '0.00');
  String _refundMethod = PaymentMethod.cash;
  List<Map<String, Object?>> _invoices = [];
  List<_SupplierReturnLineDraft> _lines = [];
  int? _purchaseId;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  @override
  void dispose() {
    _reason.dispose();
    _refundAmount.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInvoices() async {
    try {
      final invoices = await widget.repository.supplierReturnablePurchases();
      if (!mounted) return;
      setState(() {
        _invoices = invoices;
        _purchaseId = invoices.isEmpty ? null : invoices.first['id'] as int;
        _loading = false;
      });
      if (_purchaseId != null) await _loadLines(_purchaseId!);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = appErrorMessage(error,
          fallback: 'تعذر تحميل فواتير الشراء القابلة للمرتجع.',
          operation: 'supplierReturns.invoices');
      });
    }
  }

  Future<void> _loadLines(int purchaseId) async {
    setState(() => _loading = true);
    try {
      final rows = await widget.repository.supplierReturnableItems(purchaseId);
      if (!mounted) return;
      for (final line in _lines) {
        line.dispose();
      }
      setState(() {
        _lines = rows.map(_SupplierReturnLineDraft.new).toList();
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = appErrorMessage(error,
          fallback: 'تعذر تحميل أصناف الفاتورة.',
          operation: 'supplierReturns.items');
      });
    }
  }

  String _money(int value) =>
      '${value ~/ 100}.${(value % 100).toString().padLeft(2, '0')} ج.م';

  int? _parseMoney(String value) {
    final match = RegExp(r'^(\\d+)(?:[.,](\\d{1,2}))?
    final purchaseId = _purchaseId;
    if (purchaseId == null || _saving) return;
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'اكتب سبب المرتجع أولًا.');
      return;
    }
    final items = <SupplierReturnLineInput>[];
    var returnTotalMinor = 0;
    for (final line in _lines) {
      final data = line.data;
      final text = line.quantity.text.trim();
      if (text.isEmpty) continue;
      final quantity = Quantity.parse(
        text,
        allowsFraction: data['allows_fraction'] == 1,
      );
      final remaining = (data['quantity']! as num).toInt() -
          (data['returned_quantity']! as num).toInt();
      final available = (data['available_quantity']! as num).toInt();
      if (quantity == null || quantity <= 0) {
        setState(() => _error = 'أدخل كمية صحيحة للصنف ${data['product_name']}.');
        return;
      }
      if (quantity > remaining) {
        setState(() => _error = 'كمية ${data['product_name']} تتجاوز المتبقي من الفاتورة.');
        return;
      }
      if (quantity > available) {
        setState(() => _error = 'المخزون الحالي من ${data['product_name']} لا يكفي للمرتجع.');
        return;
      }
      items.add(SupplierReturnLineInput(
        purchaseItemId: data['purchase_item_id']! as int,
        quantity: quantity,
      ));
      returnTotalMinor += Quantity.lineTotalMinor(
        unitPriceMinor: (data['unit_cost_minor']! as num).toInt(),
        quantityScaled: quantity,
      );
    }
    if (items.isEmpty) {
      setState(() => _error = 'أدخل كمية مرتجعة لصنف واحد على الأقل.');
      return;
    }
    final refundedMinor = _parseMoney(_refundAmount.text);
    if (refundedMinor == null) {
      setState(() => _error = 'أدخل مبلغ الاسترداد بصيغة صحيحة.');
      return;
    }
    if (refundedMinor > returnTotalMinor) {
      setState(() => _error = 'المبلغ المسترد لا يمكن أن يتجاوز قيمة المرتجع: ${_money(returnTotalMinor)}');
      return;
    }

    setState(() { _saving = true; _error = null; });
    try {
      final id = await widget.repository.createSupplierReturn(
        purchaseId: purchaseId,
        items: items,
        reason: _reason.text,
        refundedMinor: refundedMinor,
        refundMethod: _refundMethod,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = appErrorMessage(error,
          fallback: 'تعذر حفظ مرتجع المورد.',
          operation: 'supplierReturns.create');
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إنشاء مرتجع مورد'),
    content: SizedBox(
      width: 520,
      child: _loading
          ? const SizedBox(height: 120,
              child: Center(child: CircularProgressIndicator()))
          : _error != null && _invoices.isEmpty
              ? Text(_error!)
              : _invoices.isEmpty
                  ? const Text('لا توجد فواتير بها كميات متبقية قابلة للمرتجع.')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          initialValue: _purchaseId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'فاتورة الشراء الأصلية'),
                          items: [
                            for (final invoice in _invoices)
                              DropdownMenuItem(
                                value: invoice['id']! as int,
                                child: Text(
                                  'فاتورة #${invoice['id']} — ${invoice['supplier_name']} — ${_money((invoice['total_minor']! as num).toInt())}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _saving ? null : (value) {
                            if (value == null) return;
                            setState(() => _purchaseId = value);
                            _loadLines(value);
                          },
                        ),
                        const SizedBox(height: 10),
                        if (_error != null)
                          Align(alignment: Alignment.centerRight,
                            child: Text(_error!,
                              style: TextStyle(color: Theme.of(context).colorScheme.error))),
                        Flexible(
                          child: _lines.isEmpty
                              ? const Center(child: Text('لا توجد أصناف متاحة للمرتجع في هذه الفاتورة.'))
                              : ListView(
                                  shrinkWrap: true,
                                  children: [
                                    for (final line in _lines)
                                      Card(
                                        child: Padding(
                                          padding: const EdgeInsets.all(10),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Text(line.data['product_name']! as String,
                                                style: const TextStyle(fontWeight: FontWeight.w700)),
                                              Text(
                                                'المتبقي من الفاتورة: ${Quantity.format((line.data['quantity']! as num).toInt() - (line.data['returned_quantity']! as num).toInt())} ${line.data['unit_name']} • المتاح بالمخزن: ${Quantity.format((line.data['available_quantity']! as num).toInt())}',
                                                style: Theme.of(context).textTheme.bodySmall,
                                              ),
                                              Text('تكلفة الوحدة: ${_money((line.data['unit_cost_minor']! as num).toInt())}',
                                                style: Theme.of(context).textTheme.bodySmall),
                                              TextField(
                                                controller: line.quantity,
                                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                decoration: InputDecoration(
                                                  labelText: 'الكمية المرتجعة (${line.data['unit_name']})',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                        TextField(
                          controller: _reason,
                          decoration: const InputDecoration(
                            labelText: 'سبب المرتجع *',
                            hintText: 'مثال: بضاعة تالفة أو غير مطابقة',
                          ),
                        ),
                        TextField(
                          controller: _refundAmount,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'المبلغ الذي أعاده المورد فعليًا (جنيه)',
                            helperText: 'اتركه صفرًا إذا سيُخصم من رصيد المورد فقط',
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _refundMethod,
                          decoration: const InputDecoration(labelText: 'طريقة استرداد المبلغ'),
                          items: PaymentMethod.labels.entries.map((entry) =>
                            DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
                          onChanged: _saving ? null : (value) {
                            if (value != null) setState(() => _refundMethod = value);
                          },
                        ),
                      ],
                    ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed: _loading || _saving || _invoices.isEmpty ? null : _save,
        child: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ المرتجع'),
      ),
    ],
  );
}
).firstMatch(value.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  }

  Future<void> _save() async {
    final purchaseId = _purchaseId;
    if (purchaseId == null || _saving) return;
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'اكتب سبب المرتجع أولًا.');
      return;
    }
    final items = <SupplierReturnLineInput>[];
    for (final line in _lines) {
      final data = line.data;
      final text = line.quantity.text.trim();
      if (text.isEmpty) continue;
      final quantity = Quantity.parse(
        text,
        allowsFraction: data['allows_fraction'] == 1,
      );
      final remaining = (data['quantity']! as num).toInt() -
          (data['returned_quantity']! as num).toInt();
      final available = (data['available_quantity']! as num).toInt();
      if (quantity == null || quantity <= 0) {
        setState(() => _error = 'أدخل كمية صحيحة للصنف ${data['product_name']}.');
        return;
      }
      if (quantity > remaining) {
        setState(() => _error = 'كمية ${data['product_name']} تتجاوز المتبقي من الفاتورة.');
        return;
      }
      if (quantity > available) {
        setState(() => _error = 'المخزون الحالي من ${data['product_name']} لا يكفي للمرتجع.');
        return;
      }
      items.add(SupplierReturnLineInput(
        purchaseItemId: data['purchase_item_id']! as int,
        quantity: quantity,
      ));
    }
    if (items.isEmpty) {
      setState(() => _error = 'أدخل كمية مرتجعة لصنف واحد على الأقل.');
      return;
    }

    setState(() { _saving = true; _error = null; });
    try {
      final id = await widget.repository.createSupplierReturn(
        purchaseId: purchaseId,
        items: items,
        reason: _reason.text,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = appErrorMessage(error,
          fallback: 'تعذر حفظ مرتجع المورد.',
          operation: 'supplierReturns.create');
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إنشاء مرتجع مورد'),
    content: SizedBox(
      width: 520,
      child: _loading
          ? const SizedBox(height: 120,
              child: Center(child: CircularProgressIndicator()))
          : _error != null && _invoices.isEmpty
              ? Text(_error!)
              : _invoices.isEmpty
                  ? const Text('لا توجد فواتير بها كميات متبقية قابلة للمرتجع.')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          initialValue: _purchaseId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'فاتورة الشراء الأصلية'),
                          items: [
                            for (final invoice in _invoices)
                              DropdownMenuItem(
                                value: invoice['id']! as int,
                                child: Text(
                                  'فاتورة #${invoice['id']} — ${invoice['supplier_name']} — ${_money((invoice['total_minor']! as num).toInt())}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _saving ? null : (value) {
                            if (value == null) return;
                            setState(() => _purchaseId = value);
                            _loadLines(value);
                          },
                        ),
                        const SizedBox(height: 10),
                        if (_error != null)
                          Align(alignment: Alignment.centerRight,
                            child: Text(_error!,
                              style: TextStyle(color: Theme.of(context).colorScheme.error))),
                        Flexible(
                          child: _lines.isEmpty
                              ? const Center(child: Text('لا توجد أصناف متاحة للمرتجع في هذه الفاتورة.'))
                              : ListView(
                                  shrinkWrap: true,
                                  children: [
                                    for (final line in _lines)
                                      Card(
                                        child: Padding(
                                          padding: const EdgeInsets.all(10),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Text(line.data['product_name']! as String,
                                                style: const TextStyle(fontWeight: FontWeight.w700)),
                                              Text(
                                                'المتبقي من الفاتورة: ${Quantity.format((line.data['quantity']! as num).toInt() - (line.data['returned_quantity']! as num).toInt())} ${line.data['unit_name']} • المتاح بالمخزن: ${Quantity.format((line.data['available_quantity']! as num).toInt())}',
                                                style: Theme.of(context).textTheme.bodySmall,
                                              ),
                                              Text('تكلفة الوحدة: ${_money((line.data['unit_cost_minor']! as num).toInt())}',
                                                style: Theme.of(context).textTheme.bodySmall),
                                              TextField(
                                                controller: line.quantity,
                                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                decoration: InputDecoration(
                                                  labelText: 'الكمية المرتجعة (${line.data['unit_name']})',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                        TextField(
                          controller: _reason,
                          decoration: const InputDecoration(
                            labelText: 'سبب المرتجع *',
                            hintText: 'مثال: بضاعة تالفة أو غير مطابقة',
                          ),
                        ),
                      ],
                    ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed: _loading || _saving || _invoices.isEmpty ? null : _save,
        child: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ المرتجع'),
      ),
    ],
  );
}
