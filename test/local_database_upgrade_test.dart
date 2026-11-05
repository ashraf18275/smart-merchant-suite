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

  test('upgrades version 19 to branch-scoped expenses and per-device cash drawers', () async {
    final branchId = (await database.query('branches', columns: ['id'])).single['id']! as int;
    final legacyExpenseId = await database.insert('expenses', {
      'description': 'مصروف تاريخي',
      'category': 'قديم',
      'amount_minor': 500,
      'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
    });
    final legacySessionId = await database.insert('cash_sessions', {
      'opened_at': DateTime.utc(2026, 1, 1).toIso8601String(),
      'opening_balance_minor': 1000,
      'status': 'open',
    });

    await database.execute('DROP INDEX IF EXISTS idx_cash_sessions_single_open_drawer');
    await database.execute('DROP INDEX IF EXISTS idx_cash_sessions_branch_status');
    await database.execute('DROP INDEX IF EXISTS idx_cash_sessions_drawer_status');
    await database.execute('DROP INDEX IF EXISTS idx_cash_transactions_branch_created');
    await database.execute('DROP INDEX IF EXISTS idx_cash_transactions_drawer_created');
    await database.execute('DROP INDEX IF EXISTS idx_cash_drawers_branch_active');
    await database.execute('DROP INDEX IF EXISTS idx_expenses_branch_created');
    await database.execute('DROP INDEX IF EXISTS idx_cash_sessions_single_open');
    await database.execute('DROP TABLE cash_drawers');
    await database.execute('ALTER TABLE expenses DROP COLUMN branch_id');
    await database.execute('ALTER TABLE cash_sessions DROP COLUMN branch_id');
    await database.execute('ALTER TABLE cash_sessions DROP COLUMN cash_drawer_id');
    await database.execute('ALTER TABLE cash_sessions DROP COLUMN device_id');
    await database.execute('ALTER TABLE cash_sessions DROP COLUMN opened_by_user_id');
    await database.execute('ALTER TABLE cash_transactions DROP COLUMN branch_id');
    await database.execute('ALTER TABLE cash_transactions DROP COLUMN cash_drawer_id');
    await database.delete('schema_migrations', where: 'version = ?', whereArgs: [20]);

    await upgradeLocalDatabaseSchema(database, 19, 20);

    final expense = (await database.query('expenses',
      where: 'id = ?', whereArgs: [legacyExpenseId])).single;
    expect(expense['branch_id'], isNull);
    final legacySession = (await database.query('cash_sessions',
      where: 'id = ?', whereArgs: [legacySessionId])).single;
    expect(legacySession['branch_id'], isNull);
    expect(legacySession['cash_drawer_id'], isNull);

    final drawerA = await database.insert('cash_drawers', {
      'branch_id': branchId,
      'device_id': 'device-a',
      'label': 'كاشير 1',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final drawerB = await database.insert('cash_drawers', {
      'branch_id': branchId,
      'device_id': 'device-b',
      'label': 'كاشير 2',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    Future<int> openFor(int drawerId, String deviceId) => database.insert('cash_sessions', {
      'branch_id': branchId,
      'cash_drawer_id': drawerId,
      'device_id': deviceId,
      'opened_at': DateTime.now().toUtc().toIso8601String(),
      'opening_balance_minor': 0,
      'status': 'open',
    });
    await openFor(drawerA, 'device-a');
    await openFor(drawerB, 'device-b');
    await expectLater(openFor(drawerA, 'device-a'), throwsA(anything));

    final versions = await database.query('schema_migrations',
      columns: ['version'], where: 'version = ?', whereArgs: [20]);
    expect(versions, hasLength(1));
  });
}
