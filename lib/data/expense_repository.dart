import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/expense_store.dart';
import '../core/app_error.dart';
import '../domain/branch.dart';
import '../domain/expense_record.dart';
import '../domain/profit_summary.dart';
import '../domain/payment_method.dart';
import 'audit_cash_writer.dart';

class ExpenseRepository implements ExpenseStore {
  ExpenseRepository(this._db);
  final Database _db;

  @override
  Future<List<Branch>> branches() async {
    final rows = await _db.query('branches',
        where: 'is_active = 1', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map((row) => Branch(
      id: row['id']! as int,
      name: row['name']! as String,
      address: row['address'] as String?,
      phone: row['phone'] as String?,
      isActive: row['is_active'] == 1,
    )).toList(growable: false);
  }

  List<String> _dateBounds(DateTime? from, DateTime? to) {
    final bounds = <String>[];
    if (from != null) {
      bounds.add(DateTime(from.year, from.month, from.day).toUtc().toIso8601String());
    }
    if (to != null) {
      bounds.add(DateTime(to.year, to.month, to.day + 1).toUtc().toIso8601String());
    }
    return bounds;
  }

  String _datePredicate(DateTime? from, DateTime? to, String column) {
    final clauses = <String>[];
    if (from != null) clauses.add('$column >= ?');
    if (to != null) clauses.add('$column < ?');
    return clauses.isEmpty ? '' : ' AND ${clauses.join(' AND ')}';
  }

  Future<int> add({
    required String description,
    required String category,
    required int amountMinor,
    required int branchId,
    String paymentMethod = PaymentMethod.cash,
  }) async {
    final d = description.trim(), c = category.trim();
    if (d.isEmpty) throw const AppException('وصف المصروف مطلوب');
    if (c.isEmpty) throw const AppException('تصنيف المصروف مطلوب');
    if (amountMinor <= 0) throw const AppException('قيمة المصروف يجب أن تكون أكبر من صفر');
    if (branchId <= 0) throw const AppException('اختر فرعًا صالحًا');
    if (!PaymentMethod.isValid(paymentMethod)) {
      throw const AppException('طريقة الدفع المحددة غير مدعومة');
    }
    return _db.transaction((txn) async {
      final branch = await txn.query('branches',
          columns: ['id'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [branchId],
          limit: 1);
      if (branch.isEmpty) throw const AppException('اختر فرعًا نشطًا صالحًا');

      final stamp = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('expenses', {
        'description': d,
        'category': c,
        'amount_minor': amountMinor,
        'branch_id': branchId,
        'created_at': stamp,
      });
      await writeAuditEvent(txn,
          action: 'expense_recorded',
          entityType: 'expense',
          entityId: id,
          amountMinor: amountMinor,
          details: '$c — $d',
          createdAt: stamp);
      await writeCashMovement(txn,
          direction: 'out',
          category: 'expense',
          amountMinor: amountMinor,
          sourceType: 'expense',
          sourceId: id,
          note: '$c — $d',
          createdAt: stamp,
          paymentMethod: paymentMethod,
          branchId: branchId);
      return id;
    });
  }

  @override
  Future<List<ExpenseRecord>> all({
    required int branchId,
    DateTime? from,
    DateTime? to,
  }) async {
    if (branchId <= 0) throw const AppException('اختر فرعًا صالحًا');
    final dateClause = _datePredicate(from, to, 'created_at');
    final rows = await _db.rawQuery(
      'SELECT * FROM expenses WHERE branch_id = ?$dateClause ORDER BY id DESC',
      [branchId, ..._dateBounds(from, to)]);
    return rows.map((row) => ExpenseRecord(
      id: row['id']! as int,
      description: row['description']! as String,
      category: row['category']! as String,
      amountMinor: row['amount_minor']! as int,
      createdAt: DateTime.parse(row['created_at']! as String).toLocal(),
    )).toList(growable: false);
  }

  @override
  Future<ProfitSummary> summary({
    required int branchId,
    DateTime? from,
    DateTime? to,
  }) async {
    if (branchId <= 0) throw const AppException('اختر فرعًا صالحًا');
    final bounds = _dateBounds(from, to);
    final salesDate = _datePredicate(from, to, 's.created_at');
    final returnDate = _datePredicate(from, to, 'r.created_at');
    final expenseDate = _datePredicate(from, to, 'created_at');

    // Branch reports only include documents explicitly linked to a warehouse
    // in that branch. Historical unassigned records are never guessed.
    final sales = await _db.rawQuery('''
      SELECT COALESCE(SUM(s.total_minor), 0) AS amount
      FROM sales s
      JOIN warehouses w ON w.id = s.warehouse_id
      WHERE s.cancelled_at IS NULL AND w.branch_id = ?$salesDate
    ''', [branchId, ...bounds]);
    final returns = await _db.rawQuery('''
      SELECT COALESCE(SUM(r.total_minor), 0) AS amount
      FROM customer_returns r
      JOIN warehouses w ON w.id = r.warehouse_id
      WHERE w.branch_id = ?$returnDate
    ''', [branchId, ...bounds]);
    final cost = await _db.rawQuery('''
      SELECT COALESCE(SUM((i.quantity * i.unit_cost_minor + 500) / 1000), 0) AS amount
      FROM sale_items i
      JOIN sales s ON s.id = i.sale_id
      JOIN warehouses w ON w.id = s.warehouse_id
      WHERE s.cancelled_at IS NULL AND w.branch_id = ?$salesDate
    ''', [branchId, ...bounds]);
    final returnCost = await _db.rawQuery('''
      SELECT COALESCE(SUM(i.line_cost_minor), 0) AS amount
      FROM customer_return_items i
      JOIN customer_returns r ON r.id = i.customer_return_id
      JOIN warehouses w ON w.id = r.warehouse_id
      WHERE w.branch_id = ?$returnDate
    ''', [branchId, ...bounds]);
    final expenses = await _db.rawQuery(
      'SELECT COALESCE(SUM(amount_minor), 0) AS amount FROM expenses WHERE branch_id = ?$expenseDate',
      [branchId, ...bounds]);

    return ProfitSummary(
      salesMinor: (sales.single['amount']! as num).toInt() -
          (returns.single['amount']! as num).toInt(),
      costOfGoodsMinor: (cost.single['amount']! as num).toInt() -
          (returnCost.single['amount']! as num).toInt(),
      expensesMinor: (expenses.single['amount']! as num).toInt(),
    );
  }
}
