import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/expense_store.dart';
import '../core/app_error.dart';
import '../domain/expense_record.dart';
import '../domain/profit_summary.dart';
import 'audit_cash_writer.dart';

class ExpenseRepository implements ExpenseStore {
  ExpenseRepository(this._db);
  final Database _db;

  // Date-picker values are local calendar dates. Store/query timestamps in UTC,
  // with an exclusive next-day upper bound to include the entire selected end date.
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

  String _whereDateRange(DateTime? from, DateTime? to, String column) {
    final clauses = <String>[];
    if (from != null) clauses.add('$column >= ?');
    if (to != null) clauses.add('$column < ?');
    return clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
  }

  Future<int> add({required String description, required String category, required int amountMinor}) async {
    final d = description.trim(), c = category.trim();
    if (d.isEmpty) throw const AppException('وصف المصروف مطلوب');
    if (c.isEmpty) throw const AppException('تصنيف المصروف مطلوب');
    if (amountMinor <= 0) throw const AppException('قيمة المصروف يجب أن تكون أكبر من صفر');
    return _db.transaction((txn) async {
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final expenseId = await txn.insert('expenses', {
        'description': d, 'category': c, 'amount_minor': amountMinor,
        'created_at': createdAt,
      });
      await writeAuditEvent(txn,
        action: 'expense_recorded',
        entityType: 'expense',
        entityId: expenseId,
        amountMinor: amountMinor,
        details: '$c — $d',
        createdAt: createdAt,
      );
      await writeCashMovement(txn,
        direction: 'out',
        category: 'expense',
        amountMinor: amountMinor,
        sourceType: 'expense',
        sourceId: expenseId,
        note: '$c — $d',
        createdAt: createdAt,
      );
      return expenseId;
    });
  }

  Future<List<ExpenseRecord>> all({DateTime? from, DateTime? to}) async {
    final bounds = _dateBounds(from, to);
    final where = _whereDateRange(from, to, 'created_at');
    final rows = await _db.rawQuery(
      'SELECT * FROM expenses$where ORDER BY id DESC', bounds);
    return rows.map((r) => ExpenseRecord(
      id: r['id']! as int, description: r['description']! as String,
      category: r['category']! as String, amountMinor: r['amount_minor']! as int,
      createdAt: DateTime.parse(r['created_at']! as String).toLocal(),
    )).toList(growable: false);
  }

  Future<ProfitSummary> summary({DateTime? from, DateTime? to}) async {
    final bounds = _dateBounds(from, to);
    final salesDateWhere = _whereDateRange(from, to, 'created_at');
    final salesWhere = ' WHERE cancelled_at IS NULL' +
        (salesDateWhere.isEmpty ? '' : ' AND ' + salesDateWhere.substring(7));
    final sales = await _db.rawQuery(
      'SELECT COALESCE(SUM(total_minor), 0) AS amount FROM sales$salesWhere', bounds);
    final returnWhere = _whereDateRange(from, to, 'created_at');
    final returns = await _db.rawQuery(
      'SELECT COALESCE(SUM(total_minor), 0) AS amount FROM customer_returns$returnWhere', bounds);
    final costDateWhere = _whereDateRange(from, to, 's.created_at');
    final costWhere = ' WHERE s.cancelled_at IS NULL' +
        (costDateWhere.isEmpty ? '' : ' AND ' + costDateWhere.substring(7));
    final cost = await _db.rawQuery('''
      SELECT COALESCE(SUM((i.quantity * i.unit_cost_minor + 500) / 1000), 0) AS amount
      FROM sale_items i JOIN sales s ON s.id = i.sale_id$costWhere
    ''', bounds);
    final returnCostWhere = _whereDateRange(from, to, 'r.created_at');
    final returnCost = await _db.rawQuery('''
      SELECT COALESCE(SUM(i.line_cost_minor), 0) AS amount
      FROM customer_return_items i
      JOIN customer_returns r ON r.id = i.customer_return_id$returnCostWhere
    ''', bounds);
    final expenseWhere = _whereDateRange(from, to, 'created_at');
    final expenses = await _db.rawQuery(
      'SELECT COALESCE(SUM(amount_minor), 0) AS amount FROM expenses$expenseWhere', bounds);
    final netSales = (sales.single['amount']! as num).toInt() -
        (returns.single['amount']! as num).toInt();
    final netCost = (cost.single['amount']! as num).toInt() -
        (returnCost.single['amount']! as num).toInt();
    return ProfitSummary(
      salesMinor: netSales,
      costOfGoodsMinor: netCost,
      expensesMinor: (expenses.single['amount']! as num).toInt(),
    );
  }
}
