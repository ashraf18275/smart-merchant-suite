import 'package:sqflite_common/sqlite_api.dart';

class CashbookRepository {
  CashbookRepository(this._db);
  final Database _db;

  Future<Map<String, int>> totals() async {
    final rows = await _db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN direction = 'in' THEN amount_minor ELSE 0 END), 0) AS incoming,
        COALESCE(SUM(CASE WHEN direction = 'out' THEN amount_minor ELSE 0 END), 0) AS outgoing
      FROM cash_transactions
    ''');
    final row = rows.single;
    return {
      'incoming': (row['incoming'] as num).toInt(),
      'outgoing': (row['outgoing'] as num).toInt(),
      'balance': (row['incoming'] as num).toInt() -
          (row['outgoing'] as num).toInt(),
    };
  }

  Future<List<Map<String, Object?>>> payments({int limit = 250}) =>
      _db.query('payment_records',
        orderBy: 'created_at DESC, id DESC',
        limit: limit.clamp(1, 1000));

  Future<List<Map<String, Object?>>> movements({int limit = 250}) =>
      _db.query('cash_transactions',
        orderBy: 'created_at DESC, id DESC',
        limit: limit < 1 ? 1 : (limit > 1000 ? 1000 : limit));

  Future<List<Map<String, Object?>>> auditEvents({int limit = 250}) =>
      _db.query('audit_events',
        orderBy: 'created_at DESC, id DESC',
        limit: limit.clamp(1, 1000));
}
