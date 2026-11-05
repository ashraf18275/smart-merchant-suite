import 'package:sqflite_common/sqlite_api.dart';

/// Adds durable retry scheduling metadata to the local Outbox.
Future<void> createSyncOutboxRetryScheduleSchema(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(sync_outbox)');
  final names = columns.map((row) => row['name']).toSet();

  if (!names.contains('next_attempt_at')) {
    await db.execute(
      'ALTER TABLE sync_outbox ADD COLUMN next_attempt_at TEXT',
    );
  }
  if (!names.contains('last_attempt_at')) {
    await db.execute(
      'ALTER TABLE sync_outbox ADD COLUMN last_attempt_at TEXT',
    );
  }

  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_sync_outbox_retry_schedule
    ON sync_outbox(business_id, status, next_attempt_at, created_at)
  ''');

  await db.insert(
    'schema_migrations',
    {
      'version': 19,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}
