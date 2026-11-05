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

  test('upgrades a legacy version 19 database without assigning historical rows', () async {
    await database.close();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final legacy = database;
      await legacy.execute('''
        CREATE TABLE schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
      ''');
      await legacy.execute('''
        CREATE TABLE branches (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      await legacy.execute('''
        CREATE TABLE expenses (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          description TEXT NOT NULL,
          category TEXT NOT NULL,
          amount_minor INTEGER NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      await legacy.execute('''
        CREATE TABLE cash_sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          opened_at TEXT NOT NULL,
          opening_balance_minor INTEGER NOT NULL,
          closed_at TEXT,
          expected_balance_minor INTEGER,
          counted_balance_minor INTEGER,
          difference_minor INTEGER,
          status TEXT NOT NULL
        )
      ''');
      await legacy.execute('''
        CREATE UNIQUE INDEX idx_cash_sessions_single_open
        ON cash_sessions(status) WHERE status = 'open'
      ''');
      await legacy.execute('''
        CREATE TABLE payment_records (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          direction TEXT NOT NULL,
          payment_method TEXT NOT NULL,
          amount_minor INTEGER NOT NULL,
          source_type TEXT NOT NULL,
          source_id INTEGER,
          note TEXT,
          created_at TEXT NOT NULL
        )
      ''');
      await legacy.execute('''
        CREATE TABLE cash_transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at TEXT NOT NULL
        )
      ''');
      await legacy.insert('schema_migrations', {
        'version': 19,
        'applied_at': DateTime.utc(2026, 1, 1).toIso8601String(),
      });
      final branchId = await legacy.insert('branches', {'name': 'فرع تجريبي'});
      final expenseId = await legacy.insert('expenses', {
        'description': 'مصروف تاريخي',
        'category': 'قديم',
        'amount_minor': 500,
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
      });
      final sessionId = await legacy.insert('cash_sessions', {
        'opened_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'opening_balance_minor': 1000,
        'status': 'open',
      });

      await upgradeLocalDatabaseSchema(legacy, 19, 21);

      final expense = (await legacy.query('expenses',
        where: 'id = ?', whereArgs: [expenseId])).single;
      expect(expense['branch_id'], isNull);
      final session = (await legacy.query('cash_sessions',
        where: 'id = ?', whereArgs: [sessionId])).single;
      expect(session['branch_id'], isNull);
      expect(session['cash_drawer_id'], isNull);

      final paymentColumns = await legacy.rawQuery('PRAGMA table_info(payment_records)');
      expect(paymentColumns.map((row) => row['name']), contains('branch_id'));
      expect(await legacy.query('schema_migrations',
        where: 'version = ?', whereArgs: [21]), hasLength(1));

      final drawerA = await legacy.insert('cash_drawers', {
        'branch_id': branchId,
        'device_id': 'device-a',
        'label': 'كاشير 1',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      final drawerB = await legacy.insert('cash_drawers', {
        'branch_id': branchId,
        'device_id': 'device-b',
        'label': 'كاشير 2',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      Future<int> openFor(int drawerId, String deviceId) => legacy.insert('cash_sessions', {
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

      expect(await legacy.query('schema_migrations',
        where: 'version = ?', whereArgs: [20]), hasLength(1));
  });

  test('upgrades version 20 payment records without guessing their branch', () async {
    await database.execute('DROP INDEX IF EXISTS idx_payment_records_branch_created');
    await database.execute('ALTER TABLE payment_records DROP COLUMN branch_id');
    await database.delete('schema_migrations',
      where: 'version = ?', whereArgs: [21]);
    final paymentId = await database.insert('payment_records', {
      'direction': 'in',
      'payment_method': 'cash',
      'amount_minor': 2500,
      'source_type': 'legacy_payment',
      'source_id': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    await upgradeLocalDatabaseSchema(database, 20, 21);

    final payment = (await database.query('payment_records',
      where: 'id = ?', whereArgs: [paymentId])).single;
    expect(payment['branch_id'], isNull);
    expect(await database.query('schema_migrations',
      where: 'version = ?', whereArgs: [21]), hasLength(1));
  });


}
