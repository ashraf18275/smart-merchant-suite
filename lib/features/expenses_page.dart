import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../core/app_error.dart';
import '../data/expense_repository.dart';
import '../domain/expense_record.dart';
import '../domain/profit_summary.dart';

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
  DateTime? _from;
  DateTime? _to;
  static const categories = ['إيجار', 'مرافق', 'نقل', 'رواتب', 'صيانة', 'أخرى'];

  @override
  void initState() { super.initState(); _load(); }

  String _money(int n) => '${n ~/ 100}.${(n % 100).toString().padLeft(2, '0')} ج.م';
  String _dateLabel(DateTime? date) => date == null
      ? 'كل التواريخ'
      : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  int? _parse(String s) {
    final m = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(s.trim());
    if (m == null) return null;
    final whole = int.tryParse(m.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((m.group(2) ?? '').padRight(2, '0'));
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final v = await Future.wait([
        _repo.all(from: _from, to: _to),
        _repo.summary(from: _from, to: _to),
      ]);
      if (!mounted) return;
      setState(() { _items = v[0] as List<ExpenseRecord>; _summary = v[1] as ProfitSummary; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = appErrorMessage(e, fallback: 'تعذر تحميل التقرير.', operation: 'expenses.load'); });
    }
  }

  Future<void> _pickFrom() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context, initialDate: _from ?? _to ?? now,
      firstDate: DateTime(2000), lastDate: DateTime(now.year + 10),
      helpText: 'اختر تاريخ البداية',
    );
    if (picked == null) return;
    setState(() {
      _from = DateTime(picked.year, picked.month, picked.day);
      if (_to != null && _from!.isAfter(_to!)) _to = null;
    });
    await _load();
  }

  Future<void> _pickTo() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context, initialDate: _to ?? _from ?? now,
      firstDate: DateTime(2000), lastDate: DateTime(now.year + 10),
      helpText: 'اختر تاريخ النهاية',
    );
    if (picked == null) return;
    final date = DateTime(picked.year, picked.month, picked.day);
    if (_from != null && date.isBefore(_from!)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تاريخ النهاية يجب أن يكون مساويًا لتاريخ البداية أو بعده')),
      );
      return;
    }
    setState(() => _to = date);
    await _load();
  }

  Future<void> _clearDates() async {
    setState(() { _from = null; _to = null; });
    await _load();
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
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(appErrorMessage(e, fallback: 'تعذر حفظ المصروف.', operation: 'expenses.create')))); }
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
        Text('تحديد فترة التقرير', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: _pickFrom, icon: const Icon(Icons.calendar_month), label: Text('من: ${_dateLabel(_from)}')),
          OutlinedButton.icon(onPressed: _pickTo, icon: const Icon(Icons.event), label: Text('إلى: ${_dateLabel(_to)}')),
          if (_from != null || _to != null)
            TextButton.icon(onPressed: _clearDates, icon: const Icon(Icons.clear), label: const Text('عرض الكل')),
        ]),
        const SizedBox(height: 12),
        Text(_from == null && _to == null ? 'ملخص إجمالي منذ بداية الاستخدام' : 'ملخص الفترة المحددة',
          style: Theme.of(context).textTheme.titleMedium),
        _tile('إجمالي المبيعات', _summary.salesMinor, Icons.point_of_sale_outlined),
        _tile('تكلفة البضاعة المباعة', _summary.costOfGoodsMinor, Icons.inventory_2_outlined),
        _tile('مجمل الربح', _summary.grossProfitMinor, Icons.trending_up),
        _tile('المصروفات', _summary.expensesMinor, Icons.receipt_long_outlined),
        _tile('صافي الربح التشغيلي التقديري', _summary.netProfitMinor, Icons.account_balance_wallet_outlined),
        const SizedBox(height: 16), Text('سجل المصروفات', style: Theme.of(context).textTheme.titleMedium),
        if (_items.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('لا توجد مصروفات في الفترة المحددة.')),
        ..._items.map((e) => Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.receipt_outlined)),
          title: Text(e.description), subtitle: Text('${e.category} • ${e.createdAt.year}-${e.createdAt.month.toString().padLeft(2, '0')}-${e.createdAt.day.toString().padLeft(2, '0')}'),
          trailing: Text(_money(e.amountMinor))))),
      ]),
  );
}
