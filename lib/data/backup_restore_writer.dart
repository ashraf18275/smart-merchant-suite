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
  // Validate the complete payload before deleting anything, even when a
  // caller accidentally invokes this helper outside a transaction.
  for (final table in BackupSchema.currentTableNames) {
    if (!data.containsKey(table)) {
      throw StateError('Backup data is missing required table: $table');
    }
  }

  // Restoring business rows invalidates every pending local sync event and
  // entity map that refers to the replaced SQLite IDs. Keep device metadata
  // (including the per-installation device ID and tenant file binding), but
  // clear operational sync state atomically with the data replacement.
  await executor.delete('sync_conflicts');
  await executor.delete('sync_outbox');
  await executor.delete('sync_entity_map');
  await executor.delete('sync_cursors');

  for (final table in BackupSchema.restoreDeleteOrder) {
    await executor.delete(table);
  }
  for (final table in BackupSchema.restoreInsertOrder) {
    for (final row in data[table]!) {
      await executor.insert(
        table,
        row,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }
}
