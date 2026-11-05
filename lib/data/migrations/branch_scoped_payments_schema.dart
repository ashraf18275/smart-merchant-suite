import 'package:sqflite_common/sqlite_api.dart';

/// Adds explicit branch ownership to settlement records. Existing records stay
/// unassigned because their branch cannot be inferred safely in all cases.
Future<void> createBranchScopedPaymentsSchema(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(payment_records)');
  if (!columns.any((row) => row['name'] == 'branch_id')) {
    await db.execute(
      'ALTER TABLE payment_records ADD COLUMN branch_id INTEGER REFERENCES branches(id) ON DELETE RESTRICT',
    );
  }
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_payment_records_branch_created
    ON payment_records(branch_id, created_at DESC, id DESC)
  ''');
  await db.insert('schema_migrations', {
    'version': 21,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
