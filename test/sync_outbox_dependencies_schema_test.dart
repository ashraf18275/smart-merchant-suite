import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/sync_outbox_dependencies_schema.dart';
import 'package:smart_merchant_suite/data/migrations/sync_outbox_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('upgrades an existing version-16 outbox without losing queued events', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    await createSyncOutboxSchema(db);
    const eventId = 'event-parent';
    await db.insert('sync_outbox', {
      'event_id': eventId,
      'operation_id': 'operation-parent',
      'business_id': 'business-a',
      'entity_type': 'product',
      'local_entity_id': '7',
      'action': 'create',
      'payload_json': '{"name":"قلم"}',
      'status': 'pending',
      'attempts': 0,
      'created_at': '2026-11-05T00:00:00Z',
      'updated_at': '2026-11-05T00:00:00Z',
    });

    await createSyncOutboxDependenciesSchema(db);
    await createSyncOutboxDependenciesSchema(db);

    final columns = await db.rawQuery('PRAGMA table_info(sync_outbox)');
    expect(columns.any((row) => row['name'] == 'depends_on_event_id'), isTrue);
    final rows = await db.query('sync_outbox');
    expect(rows, hasLength(1));
    expect(rows.single['event_id'], eventId);
    expect(rows.single['depends_on_event_id'], isNull);
    final migrations = await db.query(
      'schema_migrations',
      where: 'version = ?',
      whereArgs: [17],
    );
    expect(migrations, hasLength(1));
  });
}
