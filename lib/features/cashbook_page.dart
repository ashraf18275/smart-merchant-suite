import 'package:flutter/material.dart';

import '../data/cashbook_repository.dart';

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
    ]);
    return _CashbookData(
      totals: values[0] as Map<String, int>,
      movements: values[1] as List<Map<String, Object?>>,
      events: values[2] as List<Map<String, Object?>>,
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
  });
  final Map<String, int> totals;
  final List<Map<String, Object?>> movements;
  final List<Map<String, Object?>> events;
}
