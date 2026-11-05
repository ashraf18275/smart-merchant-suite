import 'package:sqflite_common/sqlite_api.dart';

/// Adds many-to-many Outbox dependencies for transactions that reference
/// multiple local entities, such as a sale containing several products.
Future<void> createSyncOutboxDependencyEdgesSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_outbox_dependencies (
      event_id TEXT NOT NULL
        REFERENCES sync_outbox(event_id) ON DELETE CASCADE,
      depends_on_event_id TEXT NOT NULL
        REFERENCES sync_outbox(event_id) ON DELETE CASCADE,
      created_at TEXT NOT NULL,
      PRIMARY KEY (event_id, depends_on_event_id),
      CHECK (event_id <> depends_on_event_id)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_outbox_dependencies_parent
    ON sync_outbox_dependencies(depends_on_event_id, event_id)
  ''');
  await db.execute('''
    INSERT OR IGNORE INTO sync_outbox_dependencies (
      event_id, depends_on_event_id, created_at
    )
    SELECT event_id, depends_on_event_id, created_at
    FROM sync_outbox
    WHERE depends_on_event_id IS NOT NULL
  ''');
  await db.insert(
    'schema_migrations',
    {
      'version': 18,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}
