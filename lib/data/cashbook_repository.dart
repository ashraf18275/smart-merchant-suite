import 'package:sqflite_common/sqlite_api.dart';

import 'audit_cash_writer.dart';

class CashbookRepository {
  CashbookRepository(this._db);
  final Database _db;

  Future<Map<String, Object?>?> currentSession() async {
    final rows = await _db.rawQuery('''
      SELECT s.*,
        s.opening_balance_minor
          + COALESCE(SUM(CASE WHEN c.direction = 'in' THEN c.amount_minor
                              WHEN c.direction = 'out' THEN -c.amount_minor
                              ELSE 0 END), 0) AS expected_balance_minor
      FROM cash_sessions s
      LEFT JOIN cash_transactions c ON c.cash_session_id = s.id
      WHERE s.status = 'open'
      GROUP BY s.id
      LIMIT 1
    ''');
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<Map<String, Object?>>> sessionHistory({int limit = 100}) =>
      _db.query('cash_sessions',
        where: "status = 'closed'",
        orderBy: 'closed_at DESC, id DESC',
        limit: limit.clamp(1, 500));

  Future<int> openSession({
    required int openingBalanceMinor,
    String? note,
  }) async {
    if (openingBalanceMinor < 0) {
      throw ArgumentError.value(openingBalanceMinor, 'openingBalanceMinor');
    }
    return _db.transaction((txn) async {
      final active = await txn.query('cash_sessions',
        columns: ['id'], where: "status = 'open'", limit: 1);
      if (active.isNotEmpty) {
        throw StateError('توجد وردية صندوق مفتوحة بالفعل');
      }
      final stamp = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('cash_sessions', {
        'opened_at': stamp,
        'opening_balance_minor': openingBalanceMinor,
        'opening_note': _optional(note),
        'status': 'open',
      });
      await writeAuditEvent(txn,
        action: 'cash_session_opened',
        entityType: 'cash_session',
        entityId: id,
        amountMinor: openingBalanceMinor,
        details: _optional(note),
        createdAt: stamp,
      );
      return id;
    });
  }

  Future<Map<String, int>> closeSession({
    required int countedBalanceMinor,
    String? note,
  }) async {
    if (countedBalanceMinor < 0) {
      throw ArgumentError.value(countedBalanceMinor, 'countedBalanceMinor');
    }
    return _db.transaction((txn) async {
      final rows = await txn.query('cash_sessions',
        where: "status = 'open'", limit: 1);
      if (rows.isEmpty) throw StateError('لا توجد وردية صندوق مفتوحة لإغلاقها');
      final session = rows.single;
      final sessionId = session['id']! as int;
      final movementRows = await txn.rawQuery('''
        SELECT
          COALESCE(SUM(CASE WHEN direction = 'in' THEN amount_minor ELSE 0 END), 0) AS incoming,
          COALESCE(SUM(CASE WHEN direction = 'out' THEN amount_minor ELSE 0 END), 0) AS outgoing
        FROM cash_transactions
        WHERE cash_session_id = ?
      ''', [sessionId]);
      final incoming = (movementRows.single['incoming'] as num).toInt();
      final outgoing = (movementRows.single['outgoing'] as num).toInt();
      final expected = (session['opening_balance_minor']! as int) +
          incoming - outgoing;
      final difference = countedBalanceMinor - expected;
      final stamp = DateTime.now().toUtc().toIso8601String();
      await txn.update('cash_sessions', {
        'closed_at': stamp,
        'expected_balance_minor': expected,
        'counted_balance_minor': countedBalanceMinor,
        'difference_minor': difference,
        'closing_note': _optional(note),
        'status': 'closed',
      }, where: "id = ? AND status = 'open'", whereArgs: [sessionId]);
      final cleanNote = _optional(note);
      await writeAuditEvent(txn,
        action: 'cash_session_closed',
        entityType: 'cash_session',
        entityId: sessionId,
        amountMinor: difference,
        details: 'expected=' + expected.toString() +
            '; counted=' + countedBalanceMinor.toString() +
            '; difference=' + difference.toString() +
            (cleanNote == null ? '' : '; note=' + cleanNote),
        createdAt: stamp,
      );
      return {
        'session_id': sessionId,
        'opening_balance': session['opening_balance_minor']! as int,
        'incoming': incoming,
        'outgoing': outgoing,
        'expected': expected,
        'counted': countedBalanceMinor,
        'difference': difference,
      };
    });
  }

  String? _optional(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

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
