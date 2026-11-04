import 'package:sqflite_common/sqlite_api.dart';

/// Local transactional queue and mapping tables for offline-first cloud sync.
Future<void> createSyncOutboxSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_outbox (
      event_id TEXT PRIMARY KEY,
      operation_id TEXT NOT NULL UNIQUE,
      business_id TEXT,
      entity_type TEXT NOT NULL CHECK (length(trim(entity_type)) > 0),
      local_entity_id TEXT NOT NULL CHECK (length(trim(local_entity_id)) > 0),
      action TEXT NOT NULL CHECK (action IN ('create', 'update', 'delete', 'adjust')),
      payload_json TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'synced', 'failed', 'conflict')),
      attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
      remote_entity_id TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      synced_at TEXT
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_outbox_pending
    ON sync_outbox(status, created_at, event_id)
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_outbox_entity
    ON sync_outbox(entity_type, local_entity_id, created_at)
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_entity_map (
      business_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      local_entity_id TEXT NOT NULL,
      remote_entity_id TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(business_id, entity_type, local_entity_id),
      UNIQUE(business_id, entity_type, remote_entity_id)
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_cursors (
      business_id TEXT NOT NULL,
      scope TEXT NOT NULL,
      cursor_value TEXT,
      updated_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_conflicts (
      id TEXT PRIMARY KEY,
      event_id TEXT NOT NULL,
      business_id TEXT,
      entity_type TEXT NOT NULL,
      local_entity_id TEXT NOT NULL,
      conflict_type TEXT NOT NULL,
      local_payload_json TEXT NOT NULL,
      remote_payload_json TEXT,
      detected_at TEXT NOT NULL,
      resolved_at TEXT,
      resolution TEXT,
      FOREIGN KEY (event_id) REFERENCES sync_outbox(event_id)
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_conflicts_open
    ON sync_conflicts(business_id, resolved_at, detected_at)
  ''');

  await db.insert(
    'schema_migrations',
    {
      'version': 16,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}
