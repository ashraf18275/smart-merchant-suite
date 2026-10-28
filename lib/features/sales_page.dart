import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../core/app_error.dart';
import '../data/product_repository.dart';
import '../data/sales_repository.dart';

class SalesPage extends StatefulWidget {
  const SalesPage({super.key, required this.database});
  final Database database;
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  late final ProductRepository _products = ProductRepository(widget.database);
  late final SalesRepository _sales = SalesRepository(widget.database);
  List<Product> _productsList = [];
  List<SaleRecord> _salesList = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

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
      final values = await Future.wait([_products.all(), _sales.all()]);
      if (!mounted) return;
      setState(() {
        _productsList = values[0] as List<Product>;
        _salesList = values[1] as List<SaleRecord>;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = appErrorMessage(e, fallback: 'تعذر تحميل المبيعات.', operation: 'sales.load'); });
    }
  }

  Future<void> _createSale() async {
    final availableProducts = _productsList.where((p) => p.stockQuantity > 0).toList();
    if (availableProducts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف منتجًا نشطًا بكمية متاحة أولًا')),
      );
      return;
    }
    final quantityControllers = <int, TextEditingController>{
      for (final p in availableProducts) p.id!: TextEditingController(text: '0'),
    };
    final paid = TextEditingController(text: '0.00');
    final key = GlobalKey<FormState>();
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
                const Align(alignment: Alignment.centerRight, child: Text('أدخل الكمية المطلوبة أمام كل صنف، واترك غير المطلوب صفرًا.')),
                const SizedBox(height: 8),
                ...availableProducts.map((p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text('${p.name}\nالمتاح: ${p.stockQuantity} • السعر: ${_money(p.priceMinor)}')),
                    const SizedBox(width: 12),
                    SizedBox(width: 92, child: TextFormField(
                      controller: quantityControllers[p.id],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'الكمية', isDense: true),
                      validator: (v) {
                        final n = int.tryParse(v?.trim() ?? '');
                        if (n == null || n < 0) return 'عدد صحيح';
                        if (n > p.stockQuantity) return 'المتاح ${p.stockQuantity}';
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
                  validator: (v) => v == null || _parseMoney(v) == null ? 'أدخل مبلغًا صحيحًا' : null,
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
                final n = int.parse(entry.value.text.trim());
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
                'paidMinor': _parseMoney(paid.text)!,
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المبيعات والفواتير')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _createSale,
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
              : _salesList.isEmpty
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
                            '${sale.createdAt.year}-${sale.createdAt.month.toString().padLeft(2, '0')}-${sale.createdAt.day.toString().padLeft(2, '0')} • الأصناف: ${sale.itemCount}\nالمدفوع: ${_money(sale.paidMinor)} • المتبقي: ${_money(sale.remainingMinor)}',
                          ),
                          isThreeLine: true,
                          trailing: Text(_money(sale.totalMinor)),
                        ));
                      },
                    ),
    ),
  );
}
