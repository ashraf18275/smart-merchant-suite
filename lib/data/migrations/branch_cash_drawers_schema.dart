import 'package:sqflite_common/sqlite_api.dart';

/// Adds branch-scoped expenses and per-device cash drawers.
///
/// Historical rows deliberately remain unassigned: the originating branch,
/// device and operator cannot be inferred safely from old records.
Future<void> createBranchCashDrawersSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS cash_drawers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      branch_id INTEGER NOT NULL,
      device_id TEXT NOT NULL CHECK (length(trim(device_id)) > 0),
      label TEXT NOT NULL CHECK (length(trim(label)) > 0),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL,
      UNIQUE (branch_id, device_id),
      FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE RESTRICT
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_cash_drawers_branch_active
    ON cash_drawers(branch_id, is_active, id)
  ''');

  Future<void> addColumnIfMissing(
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (!columns.any((row) => row['name'] == column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  await addColumnIfMissing(
    'expenses',
    'branch_id',
    'INTEGER REFERENCES branches(id) ON DELETE RESTRICT',
  );
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_expenses_branch_created
    ON expenses(branch_id, created_at DESC, id DESC)
  ''');

  await addColumnIfMissing(
    'cash_sessions',
    'branch_id',
    'INTEGER REFERENCES branches(id) ON DELETE RESTRICT',
  );
  await addColumnIfMissing(
    'cash_sessions',
    'cash_drawer_id',
    'INTEGER REFERENCES cash_drawers(id) ON DELETE RESTRICT',
  );
  await addColumnIfMissing('cash_sessions', 'device_id', 'TEXT');
  await addColumnIfMissing('cash_sessions', 'opened_by_user_id', 'TEXT');

  // Replace the old activity-wide singleton with one open shift per drawer.
  // Legacy open shifts have a NULL drawer and remain visible for reconciliation.
  await db.execute('DROP INDEX IF EXISTS idx_cash_sessions_single_open');
  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_sessions_single_open_drawer
    ON cash_sessions(cash_drawer_id)
    WHERE status = 'open' AND cash_drawer_id IS NOT NULL
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_cash_sessions_branch_status
    ON cash_sessions(branch_id, status, opened_at DESC, id DESC)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_cash_sessions_drawer_status
    ON cash_sessions(cash_drawer_id, status, opened_at DESC, id DESC)
  ''');

  await addColumnIfMissing(
    'cash_transactions',
    'branch_id',
    'INTEGER REFERENCES branches(id) ON DELETE RESTRICT',
  );
  await addColumnIfMissing(
    'cash_transactions',
    'cash_drawer_id',
    'INTEGER REFERENCES cash_drawers(id) ON DELETE RESTRICT',
  );
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_cash_transactions_branch_created
    ON cash_transactions(branch_id, created_at DESC, id DESC)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_cash_transactions_drawer_created
    ON cash_transactions(cash_drawer_id, created_at DESC, id DESC)
  ''');

  await db.insert('schema_migrations', {
    'version': 20,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
