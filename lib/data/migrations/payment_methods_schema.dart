import 'package:sqflite_common/sqlite_api.dart';

/// Adds a unified settlement journal without treating card/bank payments as cash.
/// Existing cash movements are backfilled as cash settlements exactly once.
Future<void> createPaymentMethodsSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS payment_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
      payment_method TEXT NOT NULL CHECK (
        payment_method IN ('cash', 'card', 'bank_transfer', 'wallet')
      ),
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      source_type TEXT NOT NULL CHECK (length(trim(source_type)) > 0),
      source_id INTEGER,
      note TEXT,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_payment_records_created
    ON payment_records(created_at DESC, id DESC)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_payment_records_source
    ON payment_records(source_type, source_id, direction)
  ''');

  await db.execute('''
    INSERT INTO payment_records (
      direction, payment_method, amount_minor, source_type,
      source_id, note, created_at
    )
    SELECT c.direction, 'cash', c.amount_minor, c.source_type,
           c.source_id, c.note, c.created_at
    FROM cash_transactions c
    WHERE NOT EXISTS (
      SELECT 1
      FROM payment_records p
      WHERE p.payment_method = 'cash'
        AND p.source_type = c.source_type
        AND p.source_id IS c.source_id
        AND p.direction = c.direction
        AND p.amount_minor = c.amount_minor
        AND p.created_at = c.created_at
    )
  ''');

  await db.insert('schema_migrations', {
    'version': 14,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
