import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/sync_outbox_schema.dart';
import 'package:smart_merchant_suite/data/migrations/sync_outbox_dependencies_schema.dart';
import 'package:smart_merchant_suite/data/migrations/sync_outbox_dependency_edges_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('v18 migrates existing single-parent events into dependency edges', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    await createSyncOutboxSchema(db);
    await createSyncOutboxDependenciesSchema(db);

    const parentId = 'event-parent';
    const childId = 'event-child';
    await db.insert('sync_outbox', {
      'event_id': parentId,
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
    await db.insert('sync_outbox', {
      'event_id': childId,
      'operation_id': 'operation-child',
      'business_id': 'business-a',
      'entity_type': 'inventory_movement',
      'local_entity_id': 'movement-1',
      'action': 'adjust',
      'payload_json': '{"local_product_id":"7"}',
      'depends_on_event_id': parentId,
      'status': 'pending',
      'attempts': 0,
      'created_at': '2026-11-05T00:00:01Z',
      'updated_at': '2026-11-05T00:00:01Z',
    });

    await createSyncOutboxDependencyEdgesSchema(db);
    await createSyncOutboxDependencyEdgesSchema(db);

    final edges = await db.query('sync_outbox_dependencies');
    expect(edges, hasLength(1));
    expect(edges.single['event_id'], childId);
    expect(edges.single['depends_on_event_id'], parentId);
    expect(await db.query('sync_outbox'), hasLength(2));
    expect(
      await db.query('schema_migrations', where: 'version = ?', whereArgs: [18]),
      hasLength(1),
    );
  });
}
