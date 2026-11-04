import 'package:flutter/material.dart';

import '../data/cashbook_repository.dart';
import '../domain/payment_method.dart';

class CashbookPage extends StatefulWidget {
  const CashbookPage({super.key, required this.repository});
  final CashbookRepository repository;

  @override
  State<CashbookPage> createState() => _CashbookPageState();
}

class _CashbookPageState extends State<CashbookPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late Future<_CashbookData> _data;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _data = _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<_CashbookData> _load() async {
    final values = await Future.wait([
      widget.repository.totals(),
      widget.repository.movements(),
      widget.repository.auditEvents(),
      widget.repository.payments(),
      widget.repository.currentSession(),
      widget.repository.sessionHistory(),
    ]);
    return _CashbookData(
      totals: values[0] as Map<String, int>,
      movements: values[1] as List<Map<String, Object?>>,
      events: values[2] as List<Map<String, Object?>>,
      payments: values[3] as List<Map<String, Object?>>,
      currentSession: values[4] as Map<String, Object?>?,
      sessions: values[5] as List<Map<String, Object?>>,
    );
  }

  String _money(int value) {
    final absolute = value.abs();
    final formatted = '${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
    return '${value < 0 ? '-' : ''}$formatted ج.م';
  }

  String _date(Object? value) {
    if (value is! String) return 'وقت غير معروف';
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return 'وقت غير معروف';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}  ${two(date.hour)}:${two(date.minute)}';
  }

  String _moneyInput(int value) =>
      '${value ~/ 100}.${(value % 100).toString().padLeft(2, '0')}';

  int? _parseMoney(String value) {
    final match = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?
    'sale_receipt' => 'تحصيل مبيعات',
    'purchase_payment' => 'سداد مشتريات',
    'expense' => 'مصروف',
    'customer_receipt' => 'تحصيل من عميل',
    'supplier_payment' => 'سداد لمورد',
    'customer_return_refund' => 'رد نقدي لمرتجع',
    'sale_cancellation_refund' => 'رد نقدي لإلغاء فاتورة',
    _ => category,
  };

  String _actionLabel(String action) => switch (action) {
    'sale_created' => 'إنشاء فاتورة بيع',
    'sale_cancelled' => 'إلغاء فاتورة بيع',
    'customer_return_created' => 'تسجيل مرتجع عميل',
    'purchase_created' => 'إنشاء فاتورة شراء',
    'supplier_return_created' => 'تسجيل مرتجع مورد',
    'expense_recorded' => 'تسجيل مصروف',
    'customer_receipt_recorded' => 'تسجيل تحصيل عميل',
    'supplier_payment_recorded' => 'تسجيل سداد مورد',
    _ => action,
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('الصندوق وسجل النشاط'),
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'حركة الصندوق', icon: Icon(Icons.account_balance_wallet_outlined)),
          Tab(text: 'سجل النشاط', icon: Icon(Icons.history)),
        ],
      ),
    ),
    body: FutureBuilder<_CashbookData>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('تعذر تحميل السجل: ${snapshot.error}'));
        }
        final data = snapshot.data!;
        return TabBarView(
          controller: _tabs,
          children: [
            _buildCash(data),
            _buildAudit(data),
          ],
        );
      },
    ),
  );

  Widget _buildCash(_CashbookData data) => RefreshIndicator(
    onRefresh: () async {
      setState(() => _data = _load());
      await _data;
    },
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'يعرض الصندوق الحركات النقدية المسجلة من تاريخ تحديث النظام. '
              'العمليات الأقدم محفوظة في فواتيرها وكشوفها، ولم تُحوّل تلقائيًا إلى نقدية حتى لا نفترض وسيلة دفع غير موثقة.',
            ),
          ),
        ),
        const SizedBox(height: 10),
        _sessionCard(data),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _totalCard('إجمالي المقبوضات', data.totals['incoming']!, Colors.green)),
          const SizedBox(width: 8),
          Expanded(child: _totalCard('إجمالي المدفوعات', data.totals['outgoing']!, Colors.red)),
        ]),
        const SizedBox(height: 8),
        _totalCard('صافي حركة الصندوق', data.totals['balance']!, null),
        const SizedBox(height: 18),
        Text('آخر الحركات النقدية', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.movements.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('لا توجد حركات نقدية مسجلة بعد.')),
          )
        else
          for (final row in data.movements)
            Card(
              child: ListTile(
                leading: Icon(
                  row['direction'] == 'in' ? Icons.south_west : Icons.north_east,
                  color: row['direction'] == 'in' ? Colors.green : Colors.red,
                ),
                title: Text(_cashLabel(row['category']! as String)),
                subtitle: Text('${_date(row['created_at'])}${row['note'] == null ? '' : '\n${row['note']}'}'),
                isThreeLine: row['note'] != null,
                trailing: Text(
                  '${row['direction'] == 'in' ? '+' : '-'}${_money(row['amount_minor']! as int)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: row['direction'] == 'in' ? Colors.green : Colors.red,
                  ),
                ),
              ),
            ),
        const SizedBox(height: 18),
        Text('سجل الورديات المغلقة', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: Text('لا توجد ورديات مغلقة بعد.')),
          )
        else
          for (final session in data.sessions)
            Card(
              child: ListTile(
                leading: const Icon(Icons.event_available),
                title: Text('وردية رقم ${session['id']} • ${_date(session['closed_at'])}'),
                subtitle: Text(
                  'افتتاحي: ${_money(session['opening_balance_minor']! as int)}'
                  ' • متوقع: ${_money(session['expected_balance_minor']! as int)}'
                  ' • فعلي: ${_money(session['counted_balance_minor']! as int)}',
                ),
                trailing: Text(
                  (session['difference_minor']! as int) == 0
                      ? 'متطابق'
                      : '${(session['difference_minor']! as int) > 0 ? 'زيادة' : 'عجز'}\n${_money((session['difference_minor']! as int).abs())}',
                  textAlign: TextAlign.end,
                ),
              ),
            ),
        const SizedBox(height: 18),
        Text('المدفوعات غير النقدية', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('تُسجل هنا مدفوعات البطاقات والتحويلات والمحافظ، ولا تدخل في رصيد النقدية الفعلي.'),
        const SizedBox(height: 8),
        if (data.payments.where((row) =>
            row['payment_method'] != PaymentMethod.cash).isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('لا توجد مدفوعات إلكترونية مسجلة بعد.')),
          )
        else
          for (final row in data.payments.where((row) =>
              row['payment_method'] != PaymentMethod.cash))
            Card(
              child: ListTile(
                leading: Icon(
                  row['direction'] == 'in' ? Icons.south_west : Icons.north_east,
                ),
                title: Text(PaymentMethod.labels[row['payment_method']] ??
                    row['payment_method']! as String),
                subtitle: Text('${_date(row['created_at'])} • ${row['source_type']} #${row['source_id'] ?? '—'}'
                    '${row['note'] == null ? '' : '\n${row['note']}'}'),
                isThreeLine: row['note'] != null,
                trailing: Text(
                  '${row['direction'] == 'in' ? '+' : '-'}${_money(row['amount_minor']! as int)}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
      ],
    ),
  );

  Widget _buildAudit(_CashbookData data) => RefreshIndicator(
    onRefresh: () async {
      setState(() => _data = _load());
      await _data;
    },
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('آخر العمليات المسجلة', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.events.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('لا توجد عمليات مسجلة بعد.')),
          )
        else
          for (final row in data.events)
            Card(
              child: ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(_actionLabel(row['action']! as String)),
                subtitle: Text(
                  '${row['entity_type']} #${row['entity_id'] ?? '—'} • ${_date(row['created_at'])}'
                  '${row['details'] == null ? '' : '\n${row['details']}'}',
                ),
                isThreeLine: row['details'] != null,
                trailing: row['amount_minor'] == null
                    ? null
                    : Text(_money(row['amount_minor']! as int)),
              ),
            ),
      ],
    ),
  );

  Widget _totalCard(String label, int value, Color? color) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text(_money(value), style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          )),
        ],
      ),
    ),
  );
}

class _CashbookData {
  const _CashbookData({
    required this.totals,
    required this.movements,
    required this.events,
    required this.payments,
    required this.currentSession,
    required this.sessions,
  });
  final Map<String, int> totals;
  final List<Map<String, Object?>> movements;
  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> payments;
  final Map<String, Object?>? currentSession;
  final List<Map<String, Object?>> sessions;
}
).firstMatch(value.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  }

  Future<void> _openSession() async {
    final opening = TextEditingController(text: '0.00');
    final note = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<Map<String, Object?>?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('فتح وردية الصندوق'),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: opening,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي الفعلي بالجنيه'),
              validator: (value) => _parseMoney(value ?? '') == null
                  ? 'أدخل رصيدًا صحيحًا'
                  : null,
            ),
            TextField(
              controller: note,
              decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, {
                  'amount': _parseMoney(opening.text)!,
                  'note': note.text,
                });
              }
            },
            child: const Text('فتح الوردية'),
          ),
        ],
      ),
    );
    opening.dispose();
    note.dispose();
    if (result == null) return;
    try {
      await widget.repository.openSession(
        openingBalanceMinor: result['amount']! as int,
        note: result['note']! as String,
      );
      if (!mounted) return;
      setState(() => _data = _load());
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فتح الوردية: ${error}')),
      );
    }
  }

  Future<void> _closeSession(Map<String, Object?> session) async {
    final expected = (session['expected_balance_minor'] as num).toInt();
    final counted = TextEditingController(
      text: _moneyInput(expected < 0 ? 0 : expected),
    );
    final note = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<Map<String, Object?>?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إقفال وردية الصندوق'),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('الرصيد المتوقع: ${_money(expected)}'),
            TextFormField(
              controller: counted,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'النقدية الفعلية بعد العد بالجنيه'),
              validator: (value) => _parseMoney(value ?? '') == null
                  ? 'أدخل مبلغًا صحيحًا غير سالب'
                  : null,
            ),
            TextField(
              controller: note,
              decoration: const InputDecoration(labelText: 'ملاحظة الإقفال (اختياري)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, {
                  'amount': _parseMoney(counted.text)!,
                  'note': note.text,
                });
              }
            },
            child: const Text('تأكيد الإقفال'),
          ),
        ],
      ),
    );
    counted.dispose();
    note.dispose();
    if (result == null) return;
    try {
      final closing = await widget.repository.closeSession(
        countedBalanceMinor: result['amount']! as int,
        note: result['note']! as String,
      );
      if (!mounted) return;
      setState(() => _data = _load());
      final difference = closing['difference']!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          difference == 0
              ? 'تم إقفال الوردية دون عجز أو زيادة.'
              : 'تم إقفال الوردية. ${difference > 0 ? 'زيادة' : 'عجز'}: ${_money(difference.abs())}',
        )),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إقفال الوردية: ${error}')),
      );
    }
  }

  Widget _sessionCard(_CashbookData data) {
    final session = data.currentSession;
    if (session == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('لا توجد وردية صندوق مفتوحة.'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _openSession,
              icon: const Icon(Icons.lock_open),
              label: const Text('فتح وردية وتسجيل الرصيد الافتتاحي'),
            ),
          ]),
        ),
      );
    }
    final expected = (session['expected_balance_minor'] as num).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('وردية مفتوحة', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('بدأت: ${_date(session['opened_at'])}'),
          Text('الرصيد الافتتاحي: ${_money(session['opening_balance_minor']! as int)}'),
          Text('الرصيد المتوقع حاليًا: ${_money(expected)}'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _closeSession(session),
            icon: const Icon(Icons.lock),
            label: const Text('عد النقدية وإقفال الوردية'),
          ),
        ]),
      ),
    );
  }

  String _cashLabel(String category) => switch (category) {
    'sale_receipt' => 'تحصيل مبيعات',
    'purchase_payment' => 'سداد مشتريات',
    'expense' => 'مصروف',
    'customer_receipt' => 'تحصيل من عميل',
    'supplier_payment' => 'سداد لمورد',
    'customer_return_refund' => 'رد نقدي لمرتجع',
    'sale_cancellation_refund' => 'رد نقدي لإلغاء فاتورة',
    _ => category,
  };

  String _actionLabel(String action) => switch (action) {
    'sale_created' => 'إنشاء فاتورة بيع',
    'sale_cancelled' => 'إلغاء فاتورة بيع',
    'customer_return_created' => 'تسجيل مرتجع عميل',
    'purchase_created' => 'إنشاء فاتورة شراء',
    'supplier_return_created' => 'تسجيل مرتجع مورد',
    'expense_recorded' => 'تسجيل مصروف',
    'customer_receipt_recorded' => 'تسجيل تحصيل عميل',
    'supplier_payment_recorded' => 'تسجيل سداد مورد',
    _ => action,
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('الصندوق وسجل النشاط'),
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'حركة الصندوق', icon: Icon(Icons.account_balance_wallet_outlined)),
          Tab(text: 'سجل النشاط', icon: Icon(Icons.history)),
        ],
      ),
    ),
    body: FutureBuilder<_CashbookData>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('تعذر تحميل السجل: ${snapshot.error}'));
        }
        final data = snapshot.data!;
        return TabBarView(
          controller: _tabs,
          children: [
            _buildCash(data),
            _buildAudit(data),
          ],
        );
      },
    ),
  );

  Widget _buildCash(_CashbookData data) => RefreshIndicator(
    onRefresh: () async {
      setState(() => _data = _load());
      await _data;
    },
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'يعرض الصندوق الحركات النقدية المسجلة من تاريخ تحديث النظام. '
              'العمليات الأقدم محفوظة في فواتيرها وكشوفها، ولم تُحوّل تلقائيًا إلى نقدية حتى لا نفترض وسيلة دفع غير موثقة.',
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _totalCard('إجمالي المقبوضات', data.totals['incoming']!, Colors.green)),
          const SizedBox(width: 8),
          Expanded(child: _totalCard('إجمالي المدفوعات', data.totals['outgoing']!, Colors.red)),
        ]),
        const SizedBox(height: 8),
        _totalCard('صافي حركة الصندوق', data.totals['balance']!, null),
        const SizedBox(height: 18),
        Text('آخر الحركات النقدية', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.movements.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('لا توجد حركات نقدية مسجلة بعد.')),
          )
        else
          for (final row in data.movements)
            Card(
              child: ListTile(
                leading: Icon(
                  row['direction'] == 'in' ? Icons.south_west : Icons.north_east,
                  color: row['direction'] == 'in' ? Colors.green : Colors.red,
                ),
                title: Text(_cashLabel(row['category']! as String)),
                subtitle: Text('${_date(row['created_at'])}${row['note'] == null ? '' : '\n${row['note']}'}'),
                isThreeLine: row['note'] != null,
                trailing: Text(
                  '${row['direction'] == 'in' ? '+' : '-'}${_money(row['amount_minor']! as int)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: row['direction'] == 'in' ? Colors.green : Colors.red,
                  ),
                ),
              ),
            ),
        const SizedBox(height: 18),
        Text('المدفوعات غير النقدية', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('تُسجل هنا مدفوعات البطاقات والتحويلات والمحافظ، ولا تدخل في رصيد النقدية الفعلي.'),
        const SizedBox(height: 8),
        if (data.payments.where((row) =>
            row['payment_method'] != PaymentMethod.cash).isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('لا توجد مدفوعات إلكترونية مسجلة بعد.')),
          )
        else
          for (final row in data.payments.where((row) =>
              row['payment_method'] != PaymentMethod.cash))
            Card(
              child: ListTile(
                leading: Icon(
                  row['direction'] == 'in' ? Icons.south_west : Icons.north_east,
                ),
                title: Text(PaymentMethod.labels[row['payment_method']] ??
                    row['payment_method']! as String),
                subtitle: Text('${_date(row['created_at'])} • ${row['source_type']} #${row['source_id'] ?? '—'}'
                    '${row['note'] == null ? '' : '\n${row['note']}'}'),
                isThreeLine: row['note'] != null,
                trailing: Text(
                  '${row['direction'] == 'in' ? '+' : '-'}${_money(row['amount_minor']! as int)}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
      ],
    ),
  );

  Widget _buildAudit(_CashbookData data) => RefreshIndicator(
    onRefresh: () async {
      setState(() => _data = _load());
      await _data;
    },
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('آخر العمليات المسجلة', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.events.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('لا توجد عمليات مسجلة بعد.')),
          )
        else
          for (final row in data.events)
            Card(
              child: ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(_actionLabel(row['action']! as String)),
                subtitle: Text(
                  '${row['entity_type']} #${row['entity_id'] ?? '—'} • ${_date(row['created_at'])}'
                  '${row['details'] == null ? '' : '\n${row['details']}'}',
                ),
                isThreeLine: row['details'] != null,
                trailing: row['amount_minor'] == null
                    ? null
                    : Text(_money(row['amount_minor']! as int)),
              ),
            ),
      ],
    ),
  );

  Widget _totalCard(String label, int value, Color? color) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text(_money(value), style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          )),
        ],
      ),
    ),
  );
}

class _CashbookData {
  const _CashbookData({
    required this.totals,
    required this.movements,
    required this.events,
    required this.payments,
  });
  final Map<String, int> totals;
  final List<Map<String, Object?>> movements;
  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> payments;
}
