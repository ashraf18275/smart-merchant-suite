import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../data/account_repository.dart';
import '../data/purchase_repository.dart';
import '../domain/payment_method.dart';

/// Local customer and supplier ledgers. Balances are always derived from
/// signed ledger entries; this screen never edits a balance directly.
class AccountsPage extends StatefulWidget {
  const AccountsPage({
    super.key,
    required this.accounts,
    required this.purchases,
  });

  final AccountRepository accounts;
  final PurchaseRepository purchases;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, Object?>> _suppliers = [];
  List<Map<String, Object?>> _customers = [];
  List<Map<String, Object?>> _entries = [];
  int? _supplierId;
  int? _customerId;
  int _balance = 0;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _isSupplier => _tabs.index == 0;
  int? get _selectedId => _isSupplier ? _supplierId : _customerId;
  List<Map<String, Object?>> get _selectedItems => _isSupplier ? _suppliers : _customers;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_onTabChanged);
    _load();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabs.indexIsChanging && mounted) {
      _loadLedger();
    }
  }

  String _money(int value) {
    final absolute = value.abs();
    final formatted = '${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
    return value < 0 ? '-$formatted ج.م' : '$formatted ج.م';
  }

  int? _parseMoney(String value) {
    final match = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(value.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    if (whole == null || whole > 999999999) return null;
    return whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final suppliers = await widget.purchases.suppliers();
      final customers = await widget.accounts.customers();
      if (!mounted) return;
      setState(() {
        _suppliers = suppliers;
        _customers = customers;
        if (!_suppliers.any((item) => item['id'] == _supplierId)) {
          _supplierId = _suppliers.isEmpty ? null : _suppliers.first['id'] as int;
        }
        if (!_customers.any((item) => item['id'] == _customerId)) {
          _customerId = _customers.isEmpty ? null : _customers.first['id'] as int;
        }
        _loading = false;
      });
      await _loadLedger();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = appErrorMessage(error,
          fallback: 'تعذر تحميل الحسابات.',
          operation: 'accounts.load');
      });
    }
  }

  Future<void> _loadLedger() async {
    final id = _selectedId;
    if (id == null) {
      if (mounted) setState(() { _entries = []; _balance = 0; });
      return;
    }
    try {
      final entries = _isSupplier
          ? await widget.accounts.supplierStatement(id)
          : await widget.accounts.customerStatement(id);
      final balance = _isSupplier
          ? await widget.accounts.supplierBalance(id)
          : await widget.accounts.customerBalance(id);
      if (!mounted) return;
      setState(() { _entries = entries; _balance = balance; });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = appErrorMessage(error,
        fallback: 'تعذر تحميل كشف الحساب.',
        operation: 'accounts.statement'));
    }
  }

  Future<void> _createAccount() async {
    final isSupplier = _isSupplier;
    var name = '';
    var phone = '';
    var address = '';
    var openingText = '0.00';
    var direction = isSupplier ? 'we_owe_supplier' : 'customer_owes';
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<Map<String, Object?>?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(isSupplier ? 'إضافة مورد جديد' : 'إضافة عميل جديد'),
          content: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                autofocus: true,
                onChanged: (value) => name = value,
                decoration: InputDecoration(
                  labelText: isSupplier ? 'اسم المورد *' : 'اسم العميل *',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'الاسم مطلوب'
                    : null,
              ),
              TextField(
                onChanged: (value) => phone = value,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'رقم الهاتف'),
              ),
              TextField(
                onChanged: (value) => address = value,
                decoration: const InputDecoration(labelText: 'العنوان'),
              ),
              TextFormField(
                initialValue: openingText,
                onChanged: (value) => openingText = value,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'الرصيد الافتتاحي (جنيه)',
                  helperText: 'اتركه صفرًا إذا لم يوجد رصيد سابق',
                ),
                validator: (value) => _parseMoney(value ?? '') == null
                    ? 'أدخل مبلغًا صحيحًا غير سالب'
                    : null,
              ),
              DropdownButtonFormField<String>(
                initialValue: direction,
                decoration: const InputDecoration(labelText: 'طبيعة الرصيد الافتتاحي'),
                items: isSupplier
                    ? const [
                        DropdownMenuItem(
                          value: 'we_owe_supplier',
                          child: Text('نحن مدينون للمورد'),
                        ),
                        DropdownMenuItem(
                          value: 'supplier_owes_us',
                          child: Text('المورد مدين لنا'),
                        ),
                      ]
                    : const [
                        DropdownMenuItem(
                          value: 'customer_owes',
                          child: Text('العميل مدين لنا'),
                        ),
                        DropdownMenuItem(
                          value: 'we_owe_customer',
                          child: Text('نحن مدينون للعميل'),
                        ),
                      ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => direction = value);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                final amount = _parseMoney(openingText)!;
                final isDebit = direction == 'customer_owes' ||
                    direction == 'we_owe_supplier';
                Navigator.pop(dialogContext, {
                  'name': name.trim(),
                  'phone': phone,
                  'address': address,
                  'openingBalanceMinor': amount == 0
                      ? 0
                      : (isDebit ? amount : -amount),
                });
              },
              child: const Text('حفظ الحساب'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    try {
      final openingBalance = result['openingBalanceMinor']! as int;
      final id = isSupplier
          ? await widget.purchases.addSupplier(
              name: result['name']! as String,
              phone: result['phone']! as String,
              address: result['address']! as String,
              openingBalanceMinor: openingBalance,
            )
          : await widget.accounts.addCustomer(
              name: result['name']! as String,
              phone: result['phone']! as String,
              address: result['address']! as String,
              openingBalanceMinor: openingBalance,
            );
      if (!mounted) return;
      if (isSupplier) {
        _supplierId = id;
      } else {
        _customerId = id;
      }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isSupplier ? 'تمت إضافة المورد ورصيده الافتتاحي' : 'تمت إضافة العميل ورصيده الافتتاحي'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(appErrorMessage(
            error,
            fallback: 'تعذر إضافة الحساب.',
            operation: 'accounts.create',
          )),
        ),
      );
    }
  }

  Future<void> _recordPayment() async {
    final id = _selectedId;
    if (id == null || _saving) return;
    var amountText = '';
    var note = '';
    var paymentMethod = PaymentMethod.cash;
    final formKey = GlobalKey<FormState>();
    final isSupplier = _isSupplier;
    final result = await showDialog<Map<String, Object?>?>( 
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isSupplier ? 'تسجيل سداد للمورد' : 'تسجيل تحصيل من العميل'),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('الرصيد المتاح: ${_money(_balance)}'),
            TextFormField(
              autofocus: true,
              onChanged: (value) => amountText = value,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'المبلغ بالجنيه *'),
              validator: (value) {
                final parsed = value == null ? null : _parseMoney(value);
                if (parsed == null || parsed <= 0) return 'أدخل مبلغًا صحيحًا أكبر من صفر';
                if (parsed > _balance) return 'المبلغ أكبر من الرصيد المستحق';
                return null;
              },
            ),
            DropdownButtonFormField<String>(
              initialValue: paymentMethod,
              decoration: const InputDecoration(labelText: 'طريقة الدفع'),
              items: PaymentMethod.labels.entries.map((entry) =>
                DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
              onChanged: (value) { if (value != null) paymentMethod = value; },
            ),
            TextField(
              onChanged: (value) => note = value,
              decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, {
                  'amount': _parseMoney(amountText)!,
                  'paymentMethod': paymentMethod,
                });
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final amount = result['amount']! as int;
    final selectedPaymentMethod = result['paymentMethod']! as String;

    setState(() => _saving = true);
    try {
      if (isSupplier) {
        await widget.accounts.recordSupplierPayment(
          supplierId: id, amountMinor: amount, note: note,
          paymentMethod: selectedPaymentMethod);
      } else {
        await widget.accounts.recordCustomerReceipt(
          customerId: id, amountMinor: amount, note: note,
          paymentMethod: selectedPaymentMethod);
      }
      await _loadLedger();
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isSupplier ? 'تم تسجيل سداد المورد' : 'تم تسجيل تحصيل العميل')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appErrorMessage(error,
          fallback: 'تعذر تسجيل الحركة المالية.',
          operation: 'accounts.payment'))),
      );
    }
  }

  String _date(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return '—';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  String _entryLabel(String? type) => switch (type) {
    'purchase' => 'فاتورة مشتريات',
    'payment' => 'سداد للمورد',
    'sale' => 'فاتورة بيع',
    'receipt' => 'تحصيل من العميل',
    'return' => 'مرتجع بيع',
    'refund' => 'رد نقدي للعميل',
    'sale_cancel' => 'عكس فاتورة ملغاة',
    'receipt_reversal' => 'عكس تحصيل فاتورة',
    'refund_due' => 'مبلغ مستحق رده للعميل',
    'adjustment' => 'تسوية حساب',
    _ => 'حركة حساب',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('حسابات العملاء والموردين'),
      bottom: TabBar(
        controller: _tabs,
        tabs: const [Tab(text: 'الموردون'), Tab(text: 'العملاء')],
      ),
      actions: [IconButton(
        tooltip: 'تحديث',
        onPressed: _loading ? null : _load,
        icon: const Icon(Icons.refresh),
      )],
    ),
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
                  DropdownButtonFormField<int>(
                    key: ValueKey('account-${_tabs.index}-${_selectedId ?? 0}'),
                    initialValue: _selectedId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: _isSupplier ? 'اختر المورد' : 'اختر العميل'),
                    items: [
                      for (final item in _selectedItems)
                        DropdownMenuItem<int>(
                          value: item['id']! as int,
                          child: Text(item['name']! as String,
                            overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        if (_isSupplier) { _supplierId = value; } else { _customerId = value; }
                      });
                      _loadLedger();
                    },
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _createAccount,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: Text(_isSupplier ? 'إضافة مورد جديد' : 'إضافة عميل جديد'),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Expanded(child: Text(
                          _isSupplier ? 'المبلغ المستحق للمورد' : 'مديونية العميل',
                          style: Theme.of(context).textTheme.titleMedium,
                        )),
                        Text(_money(_balance),
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: _balance > 0 ? const Color(0xFF247A52) : null,
                          )),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _selectedId == null || _balance <= 0 || _saving
                        ? null : _recordPayment,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.payments_outlined),
                    label: Text(_isSupplier ? 'تسجيل سداد للمورد' : 'تسجيل تحصيل من العميل'),
                  ),
                  const SizedBox(height: 20),
                  Text('كشف الحساب', style: Theme.of(context).textTheme.titleMedium),
                  if (_selectedId == null)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('لا توجد حسابات مسجلة في هذا القسم.'),
                    )
                  else if (_entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('لا توجد حركات مسجلة لهذا الحساب.'),
                    )
                  else
                    for (final entry in _entries.reversed)
                      Card(
                        child: ListTile(
                          title: Text(_entryLabel(entry['entry_type']?.toString())),
                          subtitle: Text('${_date(entry['created_at'])}${entry['note'] == null ? '' : ' • ${entry['note']}'}'),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(_money((entry['amount_minor']! as num).toInt()),
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text('الرصيد: ${_money((entry['running_balance_minor']! as num).toInt())}',
                                style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
  );
}
