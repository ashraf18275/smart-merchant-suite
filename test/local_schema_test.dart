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
    expect(versions.map((row) => row['version']), [1, 2, 3, 4, 5]);

    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    expect(names, containsAll(['products', 'sales', 'sale_items', 'expenses', 'product_categories', 'product_units', 'branches', 'warehouses', 'product_warehouse_stock']));
    final units = await database.query('product_units');
    expect(units, hasLength(1));
    expect(units.single['name'], 'قطعة');
    final branches = await database.query('branches');
    expect(branches.single['name'], 'الفرع الرئيسي');
    final warehouses = await database.query('warehouses');
    expect(warehouses.single['name'], 'المخزن الرئيسي');
    expect(warehouses.single['branch_id'], branches.single['id']);
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
    await database.insert('products', {
      'name': 'منتج قديم',
      'sku': 'OLD-01',
      'cost_minor': 100,
      'price_minor': 150,
      'stock_quantity': 6,
      'is_active': 1,
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    await createCatalogSchema(database);
    await createBranchWarehouseSchema(database);
    await createSalesSchema(database);
    await createExpensesSchema(database);

    final versions = await database.query(
      'schema_migrations',
      columns: ['version'],
      orderBy: 'version ASC',
    );
    expect(versions.map((row) => row['version']), [1, 2, 3, 4, 5]);
    final migratedProduct = (await database.query('products')).single;
    expect(migratedProduct['stock_quantity'], 6);
    expect(migratedProduct['unit_id'], isNotNull);
    expect(migratedProduct['category_id'], isNull);
    final stock = (await database.query('product_warehouse_stock')).single;
    expect(stock['product_id'], migratedProduct['id']);
    expect(stock['quantity'], 6);
    final movementColumns = await database.rawQuery('PRAGMA table_info(inventory_movements)');
    expect(movementColumns.map((row) => row['name']), contains('warehouse_id'));
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('expenses'), isEmpty);
  });
}
