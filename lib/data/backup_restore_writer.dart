import 'package:sqflite_common/sqlite_api.dart';

import 'backup_schema.dart';

/// Replaces all business data inside the caller's transaction.
///
/// The caller is responsible for validating and normalizing the backup before
/// invoking this method. Any insert failure is allowed to escape so SQLite
/// rolls the entire replacement back.
Future<void> replaceBackupBusinessData(
  DatabaseExecutor executor,
  Map<String, List<Map<String, Object?>>> data,
) async {
  for (final table in BackupSchema.restoreDeleteOrder) {
    await executor.delete(table);
  }
  for (final table in BackupSchema.restoreInsertOrder) {
    final rows = data[table];
    if (rows == null) {
      throw StateError('Backup data is missing required table: $table');
    }
    for (final row in rows) {
      await executor.insert(
        table,
        row,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }
}
