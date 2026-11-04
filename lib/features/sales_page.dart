import 'package:flutter/material.dart';

import '../application/ports/product_catalog.dart';
import '../application/ports/sales_service.dart';
import '../application/ports/branch_warehouse_store.dart';
import '../core/app_error.dart';
import '../data/account_repository.dart';
import '../domain/product.dart';
import '../domain/sale_record.dart';
import '../domain/sale_return_line.dart';
import '../domain/warehouse.dart';
import '../domain/warehouse_stock.dart';
import '../core/quantity.dart';

class SalesPage extends StatefulWidget {
  const SalesPage({
    super.key,
    required this.products,
    required this.sales,
    required this.warehouseStore,
    required this.accountRepository,
  });

  final ProductCatalog products;
  final SalesService sales;
  final BranchWarehouseStore warehouseStore;
  final AccountRepository accountRepository;

  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  ProductCatalog get _products => widget.products;
  SalesService get _sales => widget.sales;
  List<Product> _productsList = [];
  List<SaleRecord> _salesList = [];
  List<Warehouse> _warehouses = [];
  List<WarehouseStock> _warehouseStock = [];
  int? _selectedWarehouseId;
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  String _quantity(int scaled) => Quantity.format(scaled);

  String _money(int minor) => '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')} ج.م';

  int? _parseMoney(String value) {
    final match = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(value.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait([
        _products.all(),
        _sales.all(),
        widget.warehouseStore.warehouses(),
      ]);
      final warehouses = values[2] as List<Warehouse>;
      final defaultWarehouse = warehouses.where((item) => item.name == 'المخزن الرئيسي' && item.branchName == 'الفرع الرئيسي');
      final selectedId = warehouses.any((item) => item.id == _selectedWarehouseId)
          ? _selectedWarehouseId
          : (defaultWarehouse.isNotEmpty ? defaultWarehouse.first.id : (warehouses.isEmpty ? null : warehouses.first.id));
      final stock = selectedId == null ? <WarehouseStock>[] : await widget.warehouseStore.stock(warehouseId: selectedId);
      final customers = await widget.accountRepository.customers();
      if (!mounted) return;
      setState(() {
        _productsList = values[0] as List<Product>;
        _salesList = values[1] as List<SaleRecord>;
        _warehouses = warehouses;
        _selectedWarehouseId = selectedId;
        _warehouseStock = stock;
        _customers = customers;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = appErrorMessage(e, fallback: 'تعذر تحميل المبيعات.', operation: 'sales.load'); });
    }
  }

  List<Map<String, Object?>> _customers = [];

  WarehouseStock _stockUnit(int? productId) {
    for (final item in _warehouseStock) {
      if (item.productId == productId) return item;
    }
    return WarehouseStock(productId: productId ?? 0, productName: '', unitName: 'وحدة', quantity: 0);
  }

  Future<void> _createSale() async {
    final quantitiesByProduct = {for (final item in _warehouseStock) item.productId: item.quantity};
    final availableProducts = _productsList.where((p) => (quantitiesByProduct[p.id] ?? 0) > 0).toList();
    if (availableProducts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف منتجًا نشطًا بكمية متاحة أولًا')),
      );
      return;
    }
    final quantityControllers = <int, TextEditingController>{
      for (final p in availableProducts) p.id!: TextEditingController(),
    };
    final paid = TextEditingController();
    final key = GlobalKey<FormState>();
    int? selectedCustomerId;
    final result = await showDialog<Map<String, Object?>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('فاتورة بيع متعددة الأصناف'),
        content: SizedBox(
          width: 520,
          child: Form(
            key: key,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Align(alignment: Alignment.centerRight, child: Text('العميل (اختياري)')),
                DropdownButtonFormField<int?>(
                  initialValue: null,
                  decoration: const InputDecoration(labelText: 'بيع نقدي بدون عميل أو اختر عميلًا'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('بيع نقدي — بدون عميل')),
                    for (final customer in _customers)
                      DropdownMenuItem<int?>(
                        value: customer['id'] as int,
                        child: Text(customer['name'] as String),
                      ),
                  ],
                  onChanged: (value) => selectedCustomerId = value,
                ),
                const SizedBox(height: 8),
                ...availableProducts.map((p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text('${p.name}\nالمتاح بالمخزن المحدد: ${_quantity(quantitiesByProduct[p.id] ?? 0)} ${_stockUnit(p.id).unitName} • السعر: ${_money(p.priceMinor)}')),
                    const SizedBox(width: 12),
                    SizedBox(width: 92, child: TextFormField(
                      controller: quantityControllers[p.id],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'الكمية', isDense: true),
                      validator: (v) {
                        final value = (v ?? '').trim();
                        final n = value.isEmpty
                            ? 0
                            : Quantity.parse(value, allowsFraction: _stockUnit(p.id).allowsFraction);
                        if (n == null || n < 0) return 'كمية غير صحيحة';
                        if (n > (quantitiesByProduct[p.id] ?? 0)) return 'المتاح ${_quantity(quantitiesByProduct[p.id] ?? 0)}';
                        return null;
                      },
                    )),
                  ]),
                )),
                const Divider(),
                TextFormField(
                  controller: paid,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'المبلغ المدفوع بالجنيه'),
                  validator: (v) {
                    final value = (v ?? '').trim();
                    return value.isEmpty || _parseMoney(value) != null
                        ? null
                        : 'أدخل مبلغًا صحيحًا';
                  },
                ),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              if (!key.currentState!.validate()) return;
              final quantities = <int, int>{};
              for (final entry in quantityControllers.entries) {
                final stockItem = _stockUnit(entry.key);
                final value = entry.value.text.trim();
                final n = value.isEmpty
                    ? 0
                    : Quantity.parse(value, allowsFraction: stockItem.allowsFraction)!;
                if (n > 0) quantities[entry.key] = n;
              }
              if (quantities.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('أدخل كمية لصنف واحد على الأقل')),
                );
                return;
              }
              Navigator.pop(ctx, {
                'quantities': quantities,
                'paidMinor': _parseMoney(paid.text.trim().isEmpty ? '0' : paid.text.trim())!,
                'customerId': selectedCustomerId,
              });
            },
            child: const Text('حفظ الفاتورة'),
          ),
        ],
      ),
    );
    for (final controller in quantityControllers.values) { controller.dispose(); }
    paid.dispose();
    if (result == null) return;
    try {
      final id = await _sales.createSale(
        quantities: Map<int, int>.from(result['quantities']! as Map),
        paidMinor: result['paidMinor']! as int,
        warehouseId: _selectedWarehouseId!,
        customerId: result['customerId'] as int?,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ الفاتورة رقم $id وتحديث مخزون الأصناف')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appErrorMessage(e, fallback: 'لم يتم حفظ الفاتورة.', operation: 'sales.create'))),
      );
    }
  }


  Future<void> _createCustomerReturn() async {
    late List<Map<String, Object?>> invoices;
    try {
      invoices = await _sales.returnableSales();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(appErrorMessage(error,
            fallback: 'تعذر تحميل فواتير المرتجع.', operation: 'sales.return.load'))),
        );
      }
      return;
    }
    if (invoices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد فواتير تحتوي على كميات قابلة للإرجاع')),
      );
      return;
    }

    var selectedSaleId = invoices.first['id']! as int;
    var lines = await _sales.returnableSaleItems(selectedSaleId);
    final quantities = <int, String>{};
    var refundedText = '0';
    var reasonText = '';
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final selectedInvoice = invoices.firstWhere(
            (invoice) => invoice['id'] == selectedSaleId,
          );
          return AlertDialog(
            title: const Text('إنشاء مرتجع عميل'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: selectedSaleId,
                      decoration: const InputDecoration(labelText: 'فاتورة البيع الأصلية'),
                      items: [
                        for (final invoice in invoices)
                          DropdownMenuItem(
                            value: invoice['id']! as int,
                            child: Text(
                              'فاتورة #${invoice['id']} • ${invoice['customer_name'] ?? 'بيع نقدي'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) async {
                        if (value == null) return;
                        final nextLines = await _sales.returnableSaleItems(value);
                        setDialogState(() {
                          selectedSaleId = value;
                          lines = nextLines;
                          quantities.clear();
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'المخزن: ${selectedInvoice['warehouse_name'] ?? 'المخزن الأصلي'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Divider(),
                    ...lines.map((line) {
                      final id = line['sale_item_id']! as int;
                      final remaining = line['remaining_quantity']! as int;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${line['product_name']}\nالمتبقي: ${_quantity(remaining)} ${line['unit_name']} • سعر الوحدة: ${_money(line['unit_price_minor']! as int)}',
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 112,
                              child: TextFormField(
                                key: ValueKey('customer_return_quantity_$id'),
                                initialValue: quantities[id] ?? '',
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(
                                  labelText: 'كمية الإرجاع',
                                  isDense: true,
                                ),
                                onChanged: (value) => quantities[id] = value,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(),
                    TextField(
                      onChanged: (value) => refundedText = value,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'المبلغ المسترد نقدًا (جنيه)',
                      ),
                    ),
                    TextField(
                      onChanged: (value) => reasonText = value,
                      decoration: const InputDecoration(labelText: 'سبب المرتجع *'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () {
                  if (reasonText.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('سبب المرتجع مطلوب')),
                    );
                    return;
                  }
                  final returnItems = <SaleReturnLineInput>[];
                  for (final line in lines) {
                    final id = line['sale_item_id']! as int;
                    final value = (quantities[id] ?? '').trim();
                    if (value.isEmpty) continue;
                    final quantity = Quantity.parse(
                      value,
                      allowsFraction: line['allows_fraction'] == 1,
                    );
                    if (quantity == null ||
                        quantity <= 0 ||
                        quantity > (line['remaining_quantity']! as int)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('راجع كميات الإرجاع؛ يجب ألا تتجاوز المتبقي من الفاتورة')),
                      );
                      return;
                    }
                    returnItems.add(SaleReturnLineInput(
                      saleItemId: id,
                      quantity: quantity,
                    ));
                  }
                  if (returnItems.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('أدخل كمية لصنف واحد على الأقل')),
                    );
                    return;
                  }
                  final refundValue = _parseMoney(
                    refundedText.trim().isEmpty ? '0' : refundedText.trim(),
                  );
                  if (refundValue == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('أدخل مبلغًا نقديًا صحيحًا')),
                    );
                    return;
                  }
                  Navigator.pop(ctx, {
                    'saleId': selectedSaleId,
                    'items': returnItems,
                    'refundedMinor': refundValue,
                    'reason': reasonText.trim(),
                  });
                },
                child: const Text('حفظ المرتجع'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null) return;

    try {
      final returnId = await _sales.createCustomerReturn(
        saleId: result['saleId']! as int,
        items: result['items']! as List<SaleReturnLineInput>,
        refundedMinor: result['refundedMinor']! as int,
        reason: result['reason']! as String,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ مرتجع العميل رقم $returnId وتحديث المخزون والحساب')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(appErrorMessage(error,
            fallback: 'لم يتم حفظ مرتجع العميل.', operation: 'sales.return.create'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المبيعات والفواتير')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _loading || _selectedWarehouseId == null ? null : _createSale,
      icon: const Icon(Icons.add_shopping_cart),
      label: const Text('فاتورة جديدة'),
    ),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                ]))
              : Column(
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: _selectedWarehouseId,
                      decoration: const InputDecoration(labelText: 'المخزن الذي ستتم منه المبيعات'),
                      items: [
                        for (final warehouse in _warehouses)
                          DropdownMenuItem(value: warehouse.id, child: Text('${warehouse.branchName} — ${warehouse.name}')),
                      ],
                      onChanged: (value) async {
                        if (value == null) return;
                        setState(() { _selectedWarehouseId = value; _loading = true; });
                        await _load();
                      },
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _loading ? null : _createCustomerReturn,
                        icon: const Icon(Icons.assignment_return_outlined),
                        label: const Text('إنشاء مرتجع عميل'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _salesList.isEmpty
                          ? const Center(child: Text('لا توجد فواتير بعد. اضغط «فاتورة جديدة» للبدء.'))
                          : ListView.separated(
                              itemCount: _salesList.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final sale = _salesList[index];
                                return Card(child: ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.receipt_long)),
                                  title: Text('فاتورة رقم ${sale.id}'),
                                  subtitle: Text(
                                    '${sale.createdAt.year}-${sale.createdAt.month.toString().padLeft(2, '0')}-${sale.createdAt.day.toString().padLeft(2, '0')} • الأصناف: ${sale.itemCount}\nالمصدر: ${sale.branchName ?? 'غير محدد'} — ${sale.warehouseName ?? 'فاتورة قديمة'}\nالمدفوع: ${_money(sale.paidMinor)} • المتبقي: ${_money(sale.remainingMinor)}',
                                  ),
                                  isThreeLine: true,
                                  trailing: Text(_money(sale.totalMinor)),
                                ));
                              },
                            ),
                    ),
                  ],
                ),
    ),
  );
}
