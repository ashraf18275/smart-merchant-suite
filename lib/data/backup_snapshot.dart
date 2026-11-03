import 'package:sqflite_common/sqlite_api.dart';

/// Creates a transactionally consistent SQLite snapshot at [destinationPath].
///
/// SQLite's VACUUM INTO reads a consistent database snapshot, including committed
/// WAL content, without copying the live database file while it may be changing.
/// The destination must not already exist and the caller must not be inside a
/// transaction.
Future<void> createSqliteBackupSnapshot(
  DatabaseExecutor database,
  String destinationPath,
) async {
  await database.execute('VACUUM INTO ?', [destinationPath]);
}
