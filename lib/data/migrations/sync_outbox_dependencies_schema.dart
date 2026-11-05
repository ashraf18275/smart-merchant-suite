import 'package:sqflite_common/sqlite_api.dart';

/// Adds explicit parent-child ordering to the local Outbox.
Future<void> createSyncOutboxDependenciesSchema(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(sync_outbox)');
  if (!columns.any((row) => row['name'] == 'depends_on_event_id')) {
    await db.execute('''
      ALTER TABLE sync_outbox
      ADD COLUMN depends_on_event_id TEXT
      REFERENCES sync_outbox(event_id) ON DELETE CASCADE
    ''');
  }

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_outbox_dependency
    ON sync_outbox(depends_on_event_id, status)
  ''');

  await db.insert(
    'schema_migrations',
    {
      'version': 17,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}
