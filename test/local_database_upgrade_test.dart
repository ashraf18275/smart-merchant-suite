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

  test('upgrades a version 16 database through dependency migrations 17 and 18', () async {
    await database.execute('DROP INDEX IF EXISTS idx_sync_outbox_dependency');
    await database.execute('ALTER TABLE sync_outbox DROP COLUMN depends_on_event_id');
    await database.execute('DROP TABLE sync_outbox_dependencies');
    await database.delete(
      'schema_migrations',
      where: 'version >= ?',
      whereArgs: [17],
    );

    await upgradeLocalDatabaseSchema(database, 16, 18);

    final columns = await database.rawQuery('PRAGMA table_info(sync_outbox)');
    expect(columns.map((row) => row['name']), contains('depends_on_event_id'));

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
    expect(versions.map((row) => row['version']), [17, 18]);

    // Re-running the upgrade is safe and does not duplicate migration markers.
    await upgradeLocalDatabaseSchema(database, 16, 18);
    expect(
      await database.query(
        'schema_migrations',
        where: 'version >= ?',
        whereArgs: [17],
      ),
      hasLength(2),
    );
  });
}
