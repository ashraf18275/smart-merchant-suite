import 'package:sqflite_common/sqlite_api.dart';

import '../core/app_error.dart';
import 'audit_cash_writer.dart';
import '../domain/payment_method.dart';

/// Account balances are derived from immutable signed ledger entries.
/// Positive = customer owes the shop / shop owes supplier.
class AccountRepository {
  AccountRepository(this._db);
  final Database _db;

  Future<int> addCustomer({
    required String name,
    String? phone,
    String? address,
    int openingBalanceMinor = 0,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw AppException('اسم العميل مطلوب');
    return _db.transaction((txn) async {
      final stamp = _now();
      final customerId = await txn.insert('customers', {
        'name': cleanName,
        'phone': _optional(phone),
        'address': _optional(address),
        'is_active': 1,
        'created_at': stamp,
      });
      if (openingBalanceMinor != 0) {
        await txn.insert('customer_account_entries', {
          'customer_id': customerId,
          'amount_minor': openingBalanceMinor,
          'entry_type': 'adjustment',
          'note': 'رصيد افتتاحي عند إنشاء الحساب',
          'created_at': stamp,
        });
      }
      await writeAuditEvent(txn,
        action: 'customer_created',
        entityType: 'customer',
        entityId: customerId,
        amountMinor: openingBalanceMinor,
        details: 'opening_balance_minor=' + openingBalanceMinor.toString(),
        createdAt: stamp,
      );
      return customerId;
    });
  }

  /// Returns active customers for selection in sales and account screens.
  Future<List<Map<String, Object?>>> customers() => _db.query(
    'customers',
    where: 'is_active = 1',
    orderBy: 'name COLLATE NOCASE ASC, id ASC',
  );

  Future<int> recordSupplierPayment({
    required int supplierId,
    required int amountMinor,
    String? note,
    String paymentMethod = PaymentMethod.cash,
  }) => _recordPayment(
    table: 'supplier_account_entries',
    ownerColumn: 'supplier_id',
    ownerId: supplierId,
    amountMinor: amountMinor,
    entryType: 'payment',
    note: note,
    balanceLabel: 'المستحق للمورد',
    paymentMethod: paymentMethod,
  );

  Future<int> recordCustomerReceipt({
    required int customerId,
    required int amountMinor,
    String? note,
    String paymentMethod = PaymentMethod.cash,
  }) => _recordPayment(
    table: 'customer_account_entries',
    ownerColumn: 'customer_id',
    ownerId: customerId,
    amountMinor: amountMinor,
    entryType: 'receipt',
    note: note,
    balanceLabel: 'مديونية العميل',
    paymentMethod: paymentMethod,
  );

  Future<int> _recordPayment({
    required String table,
    required String ownerColumn,
    required int ownerId,
    required int amountMinor,
    required String entryType,
    required String balanceLabel,
    required String paymentMethod,
    String? note,
  }) async {
    if (amountMinor <= 0) throw AppException('قيمة الدفعة يجب أن تكون أكبر من صفر');
    if (!PaymentMethod.isValid(paymentMethod)) throw AppException('طريقة الدفع المحددة غير مدعومة');
    return _db.transaction((txn) async {
      final ownerTable = ownerColumn == 'supplier_id' ? 'suppliers' : 'customers';
      final owner = await txn.query(ownerTable,
        columns: ['id'], where: 'id = ? AND is_active = 1',
        whereArgs: [ownerId], limit: 1);
      if (owner.isEmpty) throw AppException('الحساب غير موجود أو موقوف');
      final rows = await txn.rawQuery(
        'SELECT COALESCE(SUM(amount_minor), 0) AS balance FROM $table WHERE $ownerColumn = ?',
        [ownerId],
      );
      final balance = (rows.single['balance'] as num).toInt();
      if (amountMinor > balance) throw AppException('$balanceLabel أقل من قيمة الدفعة');
      final createdAt = _now();
      final entryId = await txn.insert(table, {
        ownerColumn: ownerId,
        'amount_minor': -amountMinor,
        'entry_type': entryType,
        'note': _optional(note),
        'created_at': createdAt,
      });
      final isSupplier = ownerColumn == 'supplier_id';
      await writeAuditEvent(txn,
        action: isSupplier ? 'supplier_payment_recorded' : 'customer_receipt_recorded',
        entityType: isSupplier ? 'supplier' : 'customer',
        entityId: ownerId,
        amountMinor: amountMinor,
        details: note?.trim(),
        createdAt: createdAt,
      );
      await writeCashMovement(txn,
        direction: isSupplier ? 'out' : 'in',
        category: isSupplier ? 'supplier_payment' : 'customer_receipt',
        amountMinor: amountMinor,
        sourceType: isSupplier ? 'supplier_payment' : 'customer_receipt',
        sourceId: entryId,
        note: note?.trim(),
        createdAt: createdAt,
        paymentMethod: paymentMethod,
      );
      return entryId;
    });
  }

  Future<List<Map<String, Object?>>> supplierStatement(int supplierId) =>
      _statement('supplier_account_entries', 'supplier_id', supplierId);

  Future<List<Map<String, Object?>>> customerStatement(int customerId) =>
      _statement('customer_account_entries', 'customer_id', customerId);

  Future<int> supplierBalance(int supplierId) =>
      _balance('supplier_account_entries', 'supplier_id', supplierId);

  Future<int> customerBalance(int customerId) =>
      _balance('customer_account_entries', 'customer_id', customerId);

  Future<int> _balance(String table, String ownerColumn, int ownerId) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(amount_minor), 0) AS balance FROM $table WHERE $ownerColumn = ?',
      [ownerId],
    );
    return (rows.single['balance'] as num).toInt();
  }

  Future<List<Map<String, Object?>>> _statement(
    String table, String ownerColumn, int ownerId,
  ) async {
    final rows = await _db.query(table,
      where: '$ownerColumn = ?', whereArgs: [ownerId],
      orderBy: 'created_at ASC, id ASC');
    var balance = 0;
    return rows.map((row) {
      balance += row['amount_minor']! as int;
      return <String, Object?>{...row, 'running_balance_minor': balance};
    }).toList(growable: false);
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  String? _optional(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }
}
