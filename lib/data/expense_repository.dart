import 'package:sqflite_common/sqlite_api.dart';

Future<void> createExpensesSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS expenses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      description TEXT NOT NULL CHECK (length(trim(description)) > 0),
      category TEXT NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      created_at TEXT NOT NULL
    )
  ''');
  final rows = await db.query('schema_migrations', columns: ['version'],
      where: 'version = ?', whereArgs: [3], limit: 1);
  if (rows.isEmpty) {
    await db.insert('schema_migrations', {
      'version': 3, 'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}

class ExpenseRecord {
  const ExpenseRecord({required this.id, required this.description, required this.category,
    required this.amountMinor, required this.createdAt});
  final int id;
  final String description;
  final String category;
  final int amountMinor;
  final DateTime createdAt;
}
class ProfitSummary {
  const ProfitSummary({required this.salesMinor, required this.costOfGoodsMinor, required this.expensesMinor});
  final int salesMinor;
  final int costOfGoodsMinor;
  final int expensesMinor;
  int get grossProfitMinor => salesMinor - costOfGoodsMinor;
  int get netProfitMinor => grossProfitMinor - expensesMinor;
}
class ExpenseRepository {
  ExpenseRepository(this._db);
  final Database _db;
  Future<int> add({required String description, required String category, required int amountMinor}) async {
    final d = description.trim(), c = category.trim();
    if (d.isEmpty) throw ArgumentError('وصف المصروف مطلوب');
    if (c.isEmpty) throw ArgumentError('تصنيف المصروف مطلوب');
    if (amountMinor <= 0) throw ArgumentError('قيمة المصروف يجب أن تكون أكبر من صفر');
    return _db.insert('expenses', {
      'description': d, 'category': c, 'amount_minor': amountMinor,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
  Future<List<ExpenseRecord>> all() async {
    final rows = await _db.query('expenses', orderBy: 'id DESC');
    return rows.map((r) => ExpenseRecord(
      id: r['id']! as int, description: r['description']! as String,
      category: r['category']! as String, amountMinor: r['amount_minor']! as int,
      createdAt: DateTime.parse(r['created_at']! as String).toLocal(),
    )).toList(growable: false);
  }
  Future<ProfitSummary> summary() async {
    final s = await _db.rawQuery('SELECT COALESCE(SUM(total_minor), 0) AS amount FROM sales');
    final c = await _db.rawQuery('SELECT COALESCE(SUM(quantity * unit_cost_minor), 0) AS amount FROM sale_items');
    final e = await _db.rawQuery('SELECT COALESCE(SUM(amount_minor), 0) AS amount FROM expenses');
    return ProfitSummary(salesMinor: s.single['amount']! as int,
      costOfGoodsMinor: c.single['amount']! as int, expensesMinor: e.single['amount']! as int);
  }
}
