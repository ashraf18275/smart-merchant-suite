import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });

  tearDown(() async {
    await database.close();
  });

  test('creates the current schema and records every applied version', () async {
    await createLocalSchema(database);

    final versions = await database.query(
      'schema_migrations',
      columns: ['version'],
      orderBy: 'version ASC',
    );
    expect(versions.map((row) => row['version']), [1, 2, 3]);

    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    expect(names, containsAll(['products', 'sales', 'sale_items', 'expenses']));
  });

  test('upgrades a version 1 database and safely reapplies later migrations', () async {
    await database.execute('''
      CREATE TABLE products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        sku TEXT UNIQUE,
        cost_minor INTEGER NOT NULL,
        price_minor INTEGER NOT NULL,
        stock_quantity INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE inventory_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        quantity_delta INTEGER NOT NULL,
        reason TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    await database.insert('schema_migrations', {
      'version': 1,
      'applied_at': DateTime.utc(2025).toIso8601String(),
    });

    await createSalesSchema(database);
    await createExpensesSchema(database);
    await createSalesSchema(database);
    await createExpensesSchema(database);

    final versions = await database.query(
      'schema_migrations',
      columns: ['version'],
      orderBy: 'version ASC',
    );
    expect(versions.map((row) => row['version']), [1, 2, 3]);
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('expenses'), isEmpty);
  });
}
