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
    expect(versions.map((row) => row['version']), [1, 2, 3, 4, 5, 6, 7, 8]);

    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    final saleColumns = await database.rawQuery('PRAGMA table_info(sales)');
    expect(saleColumns.map((row) => row['name']), contains('warehouse_id'));
    expect(names, containsAll(['products', 'sales', 'sale_items', 'expenses', 'product_categories', 'product_units', 'branches', 'warehouses', 'product_warehouse_stock', 'suppliers', 'purchases', 'purchase_items']));
    final units = await database.query('product_units');
    expect(units, hasLength(1));
    expect(units.single['name'], 'قطعة');
    final branches = await database.query('branches');
    expect(branches.single['name'], 'الفرع الرئيسي');
    final warehouses = await database.query('warehouses');
    expect(warehouses.single['name'], 'المخزن الرئيسي');
    expect(warehouses.single['branch_id'], branches.single['id']);
  });

  test('scales a version 6 database exactly once and preserves invoice money', () async {
    await createLocalSchema(database);
    final productId = await database.insert('products', {
      'name': 'منتج v6',
      'cost_minor': 100,
      'price_minor': 200,
      'stock_quantity': 2,
      'unit_id': (await database.query('product_units')).single['id'],
      'is_active': 1,
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    final warehouseId = (await database.query('warehouses')).single['id'];
    await database.insert('product_warehouse_stock', {
      'product_id': productId,
      'warehouse_id': warehouseId,
      'quantity': 2,
      'updated_at': DateTime.utc(2025).toIso8601String(),
    });
    final saleId = await database.insert('sales', {
      'total_minor': 400,
      'paid_minor': 100,
      'warehouse_id': warehouseId,
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    await database.insert('sale_items', {
      'sale_id': saleId,
      'product_id': productId,
      'quantity': 2,
      'unit_price_minor': 200,
      'unit_cost_minor': 100,
      'line_total_minor': 400,
    });
    await database.insert('inventory_movements', {
      'product_id': productId,
      'warehouse_id': warehouseId,
      'quantity_delta': -1,
      'reason': 'حركة v6',
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    await database.delete('schema_migrations', where: 'version = ?', whereArgs: [7]);

    await createFractionalQuantitiesSchema(database);
    expect((await database.query('products')).single['stock_quantity'], 2000);
    expect((await database.query('product_warehouse_stock')).single['quantity'], 2000);
    expect((await database.query('sale_items')).single['quantity'], 2000);
    expect((await database.query('inventory_movements')).single['quantity_delta'], -1000);
    final invoice = (await database.query('sales')).single;
    expect(invoice['total_minor'], 400);
    expect(invoice['paid_minor'], 100);

    await createFractionalQuantitiesSchema(database);
    expect((await database.query('products')).single['stock_quantity'], 2000);
    expect((await database.query('sale_items')).single['quantity'], 2000);
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
    final oldSaleId = await database.insert('sales', {
      'total_minor': 250,
      'paid_minor': 100,
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    final oldProductId = await database.insert('products', {
      'name': 'منتج قديم',
      'sku': 'OLD-01',
      'cost_minor': 100,
      'price_minor': 150,
      'stock_quantity': 6,
      'is_active': 1,
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    final historicalSaleId = await database.insert('sales', {
      'total_minor': 300,
      'paid_minor': 300,
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    await database.insert('inventory_movements', {
      'product_id': oldProductId,
      'quantity_delta': 6,
      'reason': 'رصيد افتتاحي قديم',
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    await database.insert('inventory_movements', {
      'product_id': oldProductId,
      'quantity_delta': -2,
      'reason': 'صرف قديم',
      'created_at': DateTime.utc(2025).toIso8601String(),
    });
    await createCatalogSchema(database);
    await createBranchWarehouseSchema(database);
    await createSaleWarehouseSchema(database);
    await database.insert('sale_items', {
      'sale_id': oldSaleId,
      'product_id': oldProductId,
      'quantity': 2,
      'unit_price_minor': 150,
      'unit_cost_minor': 100,
      'line_total_minor': 300,
    });
    await createFractionalQuantitiesSchema(database);
    await createSalesSchema(database);
    await createExpensesSchema(database);

    final versions = await database.query(
      'schema_migrations',
      columns: ['version'],
      orderBy: 'version ASC',
    );
    expect(versions.map((row) => row['version']), [1, 2, 3, 4, 5, 6, 7]);
    final migratedProduct = (await database.query('products')).single;
    expect(migratedProduct['stock_quantity'], 6000);
    expect(migratedProduct['unit_id'], isNotNull);
    expect(migratedProduct['category_id'], isNull);
    final stock = (await database.query('product_warehouse_stock')).single;
    expect(stock['product_id'], migratedProduct['id']);
    expect(stock['quantity'], 6000);
    final movementColumns = await database.rawQuery('PRAGMA table_info(inventory_movements)');
    expect(movementColumns.map((row) => row['name']), contains('warehouse_id'));
    final migratedMovements = await database.query('inventory_movements', orderBy: 'id ASC');
    final defaultWarehouse = (await database.query('warehouses')).single;
    expect(migratedMovements, hasLength(2));
    expect(migratedMovements[0]['warehouse_id'], defaultWarehouse['id']);
    expect(migratedMovements[0]['quantity_delta'], 6000);
    expect(migratedMovements[0]['product_id'], oldProductId);
    expect(migratedMovements[1]['quantity_delta'], -2000);
    final migratedSale = (await database.query(
      'sales',
      where: 'id = ?',
      whereArgs: [oldSaleId],
    )).single;
    expect(migratedSale['warehouse_id'], isNull);
    expect(migratedSale['total_minor'], 250);
    expect(migratedSale['paid_minor'], 100);
    final salesColumns = await database.rawQuery('PRAGMA table_info(sales)');
    expect(salesColumns.map((row) => row['name']), contains('warehouse_id'));
    final historicalSale = (await database.query(
      'sales', where: 'id = ?', whereArgs: [historicalSaleId],
    )).single;
    expect(historicalSale['warehouse_id'], isNull);
    expect(historicalSale['total_minor'], 300);
    expect(historicalSale['paid_minor'], 300);
    final migratedItem = (await database.query('sale_items', where: 'sale_id = ?', whereArgs: [oldSaleId])).single;
    expect(migratedItem['quantity'], 2000);
    expect(migratedItem['line_total_minor'], 300);
    await createFractionalQuantitiesSchema(database);
    expect((await database.query('products')).single['stock_quantity'], 6000);
    expect(await database.query('expenses'), isEmpty);
  });
}
