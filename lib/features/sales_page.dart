import 'package:flutter/material.dart';
import '../data/product_repository.dart';
import '../data/sales_repository.dart';
import 'package:sqflite_common/sqlite_api.dart';

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
  void initState() {
    super.initState();
    _load();
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
      setState(() { _loading = false; _error = 'تعذر تحميل المبيعات: $e'; });
    }
  }

  Future<void> _createSale() async {
    if (_productsList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف منتجًا نشطًا وبكمية متاحة أولًا')),
      );
      return;
    }
    int? selectedId = _productsList.first.id;
    final quantity = TextEditingController(text: '1');
    final paid = TextEditingController(text: '0.00');
    final key = GlobalKey<FormState>();
    final result = await showDialog<Map<String, int>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('تسجيل فاتورة بيع'),
          content: SizedBox(
            width: 420,
            child: Form(
              key: key,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  DropdownButtonFormField<int>(
                    initialValue: selectedId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'المنتج'),
                    items: _productsList.map((p) => DropdownMenuItem<int>(
                      value: p.id,
                      child: Text('${p.name} — المتاح ${p.stockQuantity}'),
                    )).toList(),
                    onChanged: (value) => setDialogState(() => selectedId = value),
                  ),
                  TextFormField(
                    controller: quantity,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'الكمية'),
                    validator: (v) {
                      final n = int.tryParse(v?.trim() ?? '');
                      return n == null || n <= 0 ? 'أدخل كمية صحيحة' : null;
                    },
                  ),
                  TextFormField(
                    controller: paid,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'المبلغ المدفوع بالجنيه'),
                    validator: (v) => v == null || _parseMoney(v) == null
                        ? 'أدخل مبلغًا صحيحًا'
                        : null,
                  ),
                ]),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (key.currentState!.validate() && selectedId != null) {
                  Navigator.pop(ctx, {
                    'productId': selectedId!,
                    'quantity': int.parse(quantity.text.trim()),
                    'paidMinor': _parseMoney(paid.text)!,
                  });
                }
              },
              child: const Text('حفظ الفاتورة'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    quantity.dispose();
    paid.dispose();
    if (result == null) return;
    try {
      final id = await _sales.createSingleProductSale(
        productId: result['productId']!,
        quantity: result['quantity']!,
        paidMinor: result['paidMinor']!,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ الفاتورة رقم $id وتحديث المخزون')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('لم يتم حفظ الفاتورة: $e')),
        );
      }
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
                        return Card(
                          child: ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.receipt_long)),
                            title: Text('فاتورة رقم ${sale.id}'),
                            subtitle: Text(
                              '${sale.createdAt.year}-${sale.createdAt.month.toString().padLeft(2, '0')}-${sale.createdAt.day.toString().padLeft(2, '0')} • البنود: ${sale.itemCount}\nالمدفوع: ${_money(sale.paidMinor)} • المتبقي: ${_money(sale.remainingMinor)}',
                            ),
                            isThreeLine: true,
                            trailing: Text(_money(sale.totalMinor)),
                          ),
                        );
                      },
                    ),
    ),
  );
}
