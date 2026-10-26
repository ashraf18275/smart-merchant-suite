import 'package:flutter/material.dart';
import '../data/product_repository.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, required this.repository});
  final ProductRepository repository;

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final _search = TextEditingController();
  List<Product> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _search.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.repository.all(search: _search.text);
      if (!mounted) return;
      setState(() { _items = result; _loading = false; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'تعذر تحميل المنتجات: $e'; });
    }
  }

  String _money(int minor) => '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')} ج.م';

  int? _minor(String value) {
    // Parse decimal text directly into integer piastres; avoid floating-point money.
    final normalized = value.trim().replaceAll(',', '.');
    final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(normalized);
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    if (whole == null || whole > 999999999) return null;
    final fraction = int.parse((match.group(2) ?? '').padRight(2, '0'));
    return whole * 100 + fraction;
  }

  Future<void> _add() async {
    final key = GlobalKey<FormState>();
    final name = TextEditingController();
    final sku = TextEditingController();
    final cost = TextEditingController(text: '0.00');
    final price = TextEditingController(text: '0.00');
    final stock = TextEditingController(text: '0');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة منتج'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: key,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(controller: name, autofocus: true,
                  decoration: const InputDecoration(labelText: 'اسم المنتج *'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'أدخل اسم المنتج' : null),
                TextFormField(controller: sku,
                  decoration: const InputDecoration(labelText: 'كود المنتج (اختياري)')),
                TextFormField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'التكلفة بالجنيه *'),
                  validator: (v) => v == null || _minor(v) == null ? 'أدخل تكلفة صحيحة' : null),
                TextFormField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'سعر البيع بالجنيه *'),
                  validator: (v) => v == null || _minor(v) == null ? 'أدخل سعرًا صحيحًا' : null),
                TextFormField(controller: stock, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الكمية الافتتاحية'),
                  validator: (v) { final n = int.tryParse(v?.trim() ?? ''); return n == null || n < 0 ? 'أدخل كمية صحيحة' : null; }),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); },
            child: const Text('حفظ المنتج')),
        ],
      ),
    );

    if (ok == true) {
      try {
        await widget.repository.add(Product(
          name: name.text.trim(),
          sku: sku.text.trim().isEmpty ? null : sku.text.trim(),
          costMinor: _minor(cost.text)!,
          priceMinor: _minor(price.text)!,
          stockQuantity: int.parse(stock.text.trim()),
        ));
        await _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ المنتج محليًا')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حفظ المنتج: $e')));
      }
    }
    name.dispose(); sku.dispose(); cost.dispose(); price.dispose(); stock.dispose();
  }

  Future<void> _stock(Product product) async {
    final key = GlobalKey<FormState>();
    final delta = TextEditingController();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تعديل مخزون ' + product.name),
        content: Form(key: key, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('المتاح حاليًا: ' + product.stockQuantity.toString()),
          TextFormField(controller: delta, keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(labelText: 'التغيير في الكمية', helperText: '5 للإضافة أو -2 للصرف'),
            validator: (v) { final n = int.tryParse(v?.trim() ?? ''); return n == null || n == 0 ? 'أدخل عددًا صحيحًا غير صفر' : null; }),
          TextFormField(controller: reason, decoration: const InputDecoration(labelText: 'سبب الحركة *'),
            validator: (v) => v == null || v.trim().isEmpty ? 'اكتب سبب الحركة' : null),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () { if (key.currentState!.validate()) Navigator.pop(ctx, true); },
            child: const Text('تسجيل الحركة')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await widget.repository.changeStock(productId: product.id!, quantityDelta: int.parse(delta.text.trim()), reason: reason.text.trim());
        await _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تحديث المخزون وتسجيل الحركة')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('لم يتم تعديل المخزون: $e')));
      }
    }
    delta.dispose(); reason.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المنتجات والمخزون')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('إضافة منتج')),
    body: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
      TextField(controller: _search, decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search), hintText: 'ابحث باسم المنتج أو الكود',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(tooltip: 'مسح البحث', onPressed: _search.clear, icon: const Icon(Icons.clear)),
      )),
      const SizedBox(height: 12),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
        : _error != null ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center), OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
          ]))
        : _items.isEmpty ? const Center(child: Text('لا توجد منتجات بعد. اضغط «إضافة منتج» للبدء.'))
        : ListView.separated(itemCount: _items.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
              final p = _items[i];
              final code = p.sku == null ? '' : '\nالكود: ' + p.sku!;
              return Card(child: ListTile(
                leading: CircleAvatar(child: Text(p.stockQuantity.toString())),
                title: Text(p.name),
                subtitle: Text('التكلفة: ' + _money(p.costMinor) + ' • البيع: ' + _money(p.priceMinor) + code),
                isThreeLine: p.sku != null,
                trailing: IconButton(tooltip: 'تعديل المخزون', onPressed: () => _stock(p), icon: const Icon(Icons.inventory_outlined)),
              ));
            })),
    ])),
  );
}
