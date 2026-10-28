import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/expense_store.dart';
import '../domain/expense_record.dart';
import '../domain/profit_summary.dart';

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
    return _db.insert('expenses', {
      'description': d, 'category': c, 'amount_minor': amountMinor,
      'created_at': DateTime.now().toUtc().toIso8601String(),
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
    final salesWhere = _whereDateRange(from, to, 'created_at');
    final sales = await _db.rawQuery(
      'SELECT COALESCE(SUM(total_minor), 0) AS amount FROM sales$salesWhere', bounds);
    final costWhere = _whereDateRange(from, to, 's.created_at');
    final cost = await _db.rawQuery('''
      SELECT COALESCE(SUM(i.quantity * i.unit_cost_minor), 0) AS amount
      FROM sale_items i JOIN sales s ON s.id = i.sale_id$costWhere
    ''', bounds);
    final expenseWhere = _whereDateRange(from, to, 'created_at');
    final expenses = await _db.rawQuery(
      'SELECT COALESCE(SUM(amount_minor), 0) AS amount FROM expenses$expenseWhere', bounds);
    return ProfitSummary(salesMinor: sales.single['amount']! as int,
      costOfGoodsMinor: cost.single['amount']! as int,
      expensesMinor: expenses.single['amount']! as int);
  }
}
