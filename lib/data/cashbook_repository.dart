import 'package:sqflite_common/sqlite_api.dart';

import '../domain/branch.dart';
import 'audit_cash_writer.dart';

class CashbookRepository {
  CashbookRepository(this._db);
  final Database _db;

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

  Future<Map<String, Object?>> ensureDrawer({required int branchId}) =>
      ensureCashDrawerForCurrentDevice(_db, branchId: branchId);

  Future<Map<String, Object?>?> currentSession({
    required int branchId,
    required int cashDrawerId,
  }) async {
    final rows = await _db.rawQuery('''
      SELECT s.*,
        s.opening_balance_minor
          + COALESCE(SUM(CASE WHEN c.direction = 'in' THEN c.amount_minor
                              WHEN c.direction = 'out' THEN -c.amount_minor
                              ELSE 0 END), 0) AS live_expected_balance_minor
      FROM cash_sessions s
      LEFT JOIN cash_transactions c ON c.cash_session_id = s.id
      WHERE s.status = 'open'
        AND s.branch_id = ?
        AND s.cash_drawer_id = ?
      GROUP BY s.id
      LIMIT 1
    ''', [branchId, cashDrawerId]);
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<Map<String, Object?>>> sessionHistory({
    required int branchId,
    required int cashDrawerId,
    int limit = 100,
  }) =>
      _db.query('cash_sessions',
        where: "status = 'closed' AND branch_id = ? AND cash_drawer_id = ?",
        whereArgs: [branchId, cashDrawerId],
        orderBy: 'closed_at DESC, id DESC',
        limit: limit.clamp(1, 500));

  Future<int> openSession({
    required int branchId,
    required int cashDrawerId,
    required int openingBalanceMinor,
    String? note,
  }) async {
    if (openingBalanceMinor < 0) {
      throw ArgumentError.value(openingBalanceMinor, 'openingBalanceMinor');
    }
    return _db.transaction((txn) async {
      final drawers = await txn.query('cash_drawers',
        where: 'id = ? AND branch_id = ? AND is_active = 1',
        whereArgs: [cashDrawerId, branchId],
        limit: 1);
      if (drawers.isEmpty) throw StateError('cash_drawer_missing_or_inactive');
      final drawer = drawers.single;
      final active = await txn.query('cash_sessions',
        columns: ['id'],
        where: "status = 'open' AND cash_drawer_id = ?",
        whereArgs: [cashDrawerId],
        limit: 1);
      if (active.isNotEmpty) {
        throw StateError('توجد وردية مفتوحة بالفعل على درج هذا الجهاز');
      }
      final stamp = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('cash_sessions', {
        'opened_at': stamp,
        'opening_balance_minor': openingBalanceMinor,
        'opening_note': _optional(note),
        'status': 'open',
        'branch_id': branchId,
        'cash_drawer_id': cashDrawerId,
        'device_id': drawer['device_id'],
      });
      await writeAuditEvent(txn,
        action: 'cash_session_opened',
        entityType: 'cash_session',
        entityId: id,
        amountMinor: openingBalanceMinor,
        details: 'branch_id=$branchId; cash_drawer_id=$cashDrawerId' +
            (_optional(note) == null ? '' : '; note=${_optional(note)}'),
        createdAt: stamp);
      return id;
    });
  }

  Future<Map<String, int>> closeSession({
    required int branchId,
    required int cashDrawerId,
    required int sessionId,
    required int countedBalanceMinor,
    String? note,
  }) async {
    if (countedBalanceMinor < 0) {
      throw ArgumentError.value(countedBalanceMinor, 'countedBalanceMinor');
    }
    return _db.transaction((txn) async {
      final rows = await txn.query('cash_sessions',
        where: "id = ? AND branch_id = ? AND cash_drawer_id = ? AND status = 'open'",
        whereArgs: [sessionId, branchId, cashDrawerId],
        limit: 1);
      if (rows.isEmpty) throw StateError('لا توجد وردية مفتوحة لهذا الدرج لإغلاقها');
      final session = rows.single;
      final movementRows = await txn.rawQuery('''
        SELECT
          COALESCE(SUM(CASE WHEN direction = 'in' THEN amount_minor ELSE 0 END), 0) AS incoming,
          COALESCE(SUM(CASE WHEN direction = 'out' THEN amount_minor ELSE 0 END), 0) AS outgoing
        FROM cash_transactions
        WHERE cash_session_id = ? AND branch_id = ? AND cash_drawer_id = ?
      ''', [sessionId, branchId, cashDrawerId]);
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
      }, where: "id = ? AND branch_id = ? AND cash_drawer_id = ? AND status = 'open'",
          whereArgs: [sessionId, branchId, cashDrawerId]);
      final cleanNote = _optional(note);
      await writeAuditEvent(txn,
        action: 'cash_session_closed',
        entityType: 'cash_session',
        entityId: sessionId,
        amountMinor: difference,
        details: 'branch_id=$branchId; cash_drawer_id=$cashDrawerId; expected=$expected; counted=$countedBalanceMinor; difference=$difference' +
            (cleanNote == null ? '' : '; note=$cleanNote'),
        createdAt: stamp);
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

  Future<Map<String, int>> totals({
    required int branchId,
    required int cashDrawerId,
  }) async {
    final rows = await _db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN direction = 'in' THEN amount_minor ELSE 0 END), 0) AS incoming,
        COALESCE(SUM(CASE WHEN direction = 'out' THEN amount_minor ELSE 0 END), 0) AS outgoing
      FROM cash_transactions
      WHERE branch_id = ? AND cash_drawer_id = ?
    ''', [branchId, cashDrawerId]);
    final row = rows.single;
    return {
      'incoming': (row['incoming'] as num).toInt(),
      'outgoing': (row['outgoing'] as num).toInt(),
      'balance': (row['incoming'] as num).toInt() -
          (row['outgoing'] as num).toInt(),
    };
  }

  Future<List<Map<String, Object?>>> payments({
    required int branchId,
    int limit = 250,
  }) =>
      _db.query('payment_records',
        where: 'branch_id = ?',
        whereArgs: [branchId],
        orderBy: 'created_at DESC, id DESC',
        limit: limit.clamp(1, 1000));

  Future<List<Map<String, Object?>>> movements({
    required int branchId,
    required int cashDrawerId,
    int limit = 250,
  }) =>
      _db.query('cash_transactions',
        where: 'branch_id = ? AND cash_drawer_id = ?',
        whereArgs: [branchId, cashDrawerId],
        orderBy: 'created_at DESC, id DESC',
        limit: limit < 1 ? 1 : (limit > 1000 ? 1000 : limit));

  /// The activity audit is intentionally global until audit rows gain explicit
  /// branch and device ownership; it is not used for drawer balances.
  Future<List<Map<String, Object?>>> auditEvents({int limit = 250}) =>
      _db.query('audit_events',
        orderBy: 'created_at DESC, id DESC',
        limit: limit.clamp(1, 1000));
}
