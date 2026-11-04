import 'package:sqflite_common/sqlite_api.dart';

/// Adds cash shift lifecycle tracking. Historical movements remain unassigned:
/// their originating shift and opening float cannot be inferred safely.
Future<void> createCashSessionsSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS cash_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      opened_at TEXT NOT NULL,
      opening_balance_minor INTEGER NOT NULL CHECK (opening_balance_minor >= 0),
      opening_note TEXT,
      closed_at TEXT,
      expected_balance_minor INTEGER,
      counted_balance_minor INTEGER CHECK (
        counted_balance_minor IS NULL OR counted_balance_minor >= 0
      ),
      difference_minor INTEGER,
      closing_note TEXT,
      status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
      CHECK (
        (status = 'open' AND closed_at IS NULL
          AND expected_balance_minor IS NULL
          AND counted_balance_minor IS NULL
          AND difference_minor IS NULL)
        OR
        (status = 'closed' AND closed_at IS NOT NULL
          AND expected_balance_minor IS NOT NULL
          AND counted_balance_minor IS NOT NULL
          AND difference_minor IS NOT NULL)
      )
    )
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_sessions_single_open
    ON cash_sessions(status) WHERE status = 'open'
  ''');

  final columns = await db.rawQuery('PRAGMA table_info(cash_transactions)');
  if (!columns.any((row) => row['name'] == 'cash_session_id')) {
    await db.execute(
      'ALTER TABLE cash_transactions ADD COLUMN cash_session_id INTEGER '
      'REFERENCES cash_sessions(id) ON DELETE RESTRICT',
    );
  }
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_cash_transactions_session
    ON cash_transactions(cash_session_id, created_at, id)
  ''');
  await db.insert('schema_migrations', {
    'version': 15,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
