import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/local_database_upgrade.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
  });

  tearDown(() async => database.close());

  test('upgrades a version 16 database through Outbox migrations 17 to 19', () async {
    await database.execute('DROP INDEX IF EXISTS idx_sync_outbox_dependency');
    await database.execute('ALTER TABLE sync_outbox DROP COLUMN depends_on_event_id');
    await database.execute('DROP TABLE sync_outbox_dependencies');
    await database.execute('DROP INDEX IF EXISTS idx_sync_outbox_retry_schedule');
    await database.execute('ALTER TABLE sync_outbox DROP COLUMN next_attempt_at');
    await database.execute('ALTER TABLE sync_outbox DROP COLUMN last_attempt_at');
    await database.delete(
      'schema_migrations',
      where: 'version >= ?',
      whereArgs: [17],
    );

    await upgradeLocalDatabaseSchema(database, 16, 19);

    final columns = await database.rawQuery('PRAGMA table_info(sync_outbox)');
    expect(columns.map((row) => row['name']), containsAll(['depends_on_event_id', 'next_attempt_at', 'last_attempt_at']));

    final dependencies = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_outbox_dependencies'",
    );
    expect(dependencies, hasLength(1));

    final versions = await database.query(
      'schema_migrations',
      columns: ['version'],
      where: 'version >= ?',
      whereArgs: [17],
      orderBy: 'version ASC',
    );
    expect(versions.map((row) => row['version']), [17, 18, 19]);

    // Re-running the upgrade is safe and does not duplicate migration markers.
    await upgradeLocalDatabaseSchema(database, 16, 19);
    expect(
      await database.query(
        'schema_migrations',
        where: 'version >= ?',
        whereArgs: [17],
      ),
      hasLength(3),
    );
  });
}
