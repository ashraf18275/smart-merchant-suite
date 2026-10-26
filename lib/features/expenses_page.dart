import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';
import '../data/expense_repository.dart';

class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key, required this.database});
  final Database database;
  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}
class _ExpensesPageState extends State<ExpensesPage> {
  late final ExpenseRepository _repo = ExpenseRepository(widget.database);
  List<ExpenseRecord> _items = [];
  ProfitSummary _summary = const ProfitSummary(salesMinor: 0, costOfGoodsMinor: 0, expensesMinor: 0);
  bool _loading = true;
  String? _error;
  static const categories = ['إيجار', 'مرافق', 'نقل', 'رواتب', 'صيانة', 'أخرى'];
  @override
  void initState() { super.initState(); _load(); }
  String _money(int n) => '${n ~/ 100}.${(n % 100).toString().padLeft(2, '0')} ج.م';
  int? _parse(String s) {
    final m = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(s.trim());
    if (m == null) return null;
    final whole = int.tryParse(m.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((m.group(2) ?? '').padRight(2, '0'));
  }
  Future<void> _load() async {
    try {
      final v = await Future.wait([_repo.all(), _repo.summary()]);
      if (!mounted) return;
      setState(() { _items = v[0] as List<ExpenseRecord>; _summary = v[1] as ProfitSummary; _loading = false; _error = null; });
    } catch (e) { if (!mounted) return; setState(() { _loading = false; _error = 'تعذر تحميل المصروفات: $e'; }); }
  }
  Future<void> _add() async {
    final desc = TextEditingController(), amount = TextEditingController();
    final form = GlobalKey<FormState>();
    String category = categories.first;
    final result = await showDialog<Map<String, Object?>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => AlertDialog(
        title: const Text('إضافة مصروف'),
        content: SizedBox(width: 420, child: Form(key: form, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(controller: desc, decoration: const InputDecoration(labelText: 'وصف المصروف *'),
            validator: (v) => v == null || v.trim().isEmpty ? 'أدخل وصف المصروف' : null),
          DropdownButtonFormField<String>(initialValue: category, decoration: const InputDecoration(labelText: 'التصنيف'),
            items: categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) { if (v != null) update(() => category = v); }),
          TextFormField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'القيمة بالجنيه *'),
            validator: (v) { final n = v == null ? null : _parse(v); return n == null || n <= 0 ? 'أدخل قيمة أكبر من صفر' : null; }),
        ])))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () { if (form.currentState!.validate()) Navigator.pop(ctx, {
            'description': desc.text.trim(), 'category': category, 'amount': _parse(amount.text)!,
          }); }, child: const Text('حفظ المصروف')),
        ],
      )),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    desc.dispose(); amount.dispose();
    if (result == null) return;
    try {
      await _repo.add(description: result['description']! as String, category: result['category']! as String, amountMinor: result['amount']! as int);
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ المصروف')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حفظ المصروف: $e'))); }
  }
  Widget _tile(String title, int amount, IconData icon) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
    Icon(icon), const SizedBox(width: 8), Expanded(child: Text(title)),
    Text(_money(amount), style: const TextStyle(fontWeight: FontWeight.bold)),
  ])));
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المصروفات والأرباح')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('إضافة مصروف')),
    body: _loading ? const Center(child: CircularProgressIndicator())
      : _error != null ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة'))]))
      : ListView(padding: const EdgeInsets.all(16), children: [
        Text('ملخص إجمالي منذ بداية الاستخدام', style: Theme.of(context).textTheme.titleMedium),
        _tile('إجمالي المبيعات', _summary.salesMinor, Icons.point_of_sale_outlined),
        _tile('تكلفة البضاعة المباعة', _summary.costOfGoodsMinor, Icons.inventory_2_outlined),
        _tile('مجمل الربح', _summary.grossProfitMinor, Icons.trending_up),
        _tile('المصروفات', _summary.expensesMinor, Icons.receipt_long_outlined),
        _tile('صافي الربح التشغيلي التقديري', _summary.netProfitMinor, Icons.account_balance_wallet_outlined),
        const SizedBox(height: 16), Text('سجل المصروفات', style: Theme.of(context).textTheme.titleMedium),
        if (_items.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('لا توجد مصروفات مسجلة بعد.')),
        ..._items.map((e) => Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.receipt_outlined)),
          title: Text(e.description), subtitle: Text('${e.category} • ${e.createdAt.year}-${e.createdAt.month.toString().padLeft(2, '0')}-${e.createdAt.day.toString().padLeft(2, '0')}'),
          trailing: Text(_money(e.amountMinor))))),
      ]),
  );
}
