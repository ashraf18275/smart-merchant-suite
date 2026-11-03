import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
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
    await db.execute('''
      CREATE TABLE inventory_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        quantity_delta INTEGER NOT NULL,
        reason TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    await db.insert('schema_migrations', {
      'version': 1,
      'applied_at': DateTime.utc(2025).toIso8601String(),
    });
    await createSalesSchema(db);
    await createExpensesSchema(db);
    await createCatalogSchema(db);
    await createBranchWarehouseSchema(db);
    await createSaleWarehouseSchema(db);
    await createFractionalQuantitiesSchema(db);
    await createPurchaseSchema(db);
  });

  tearDown(() async => db.close());

  test('version 8 to 9 preserves old sales and adds nullable customer reference', () async {
    final saleId = await db.insert('sales', {
      'total_minor': 12500,
      'paid_minor': 5000,
      'created_at': DateTime.utc(2025, 2).toIso8601String(),
    });

    await createAccountSchema(db);

    final sale = (await db.query('sales', where: 'id = ?', whereArgs: [saleId])).single;
    expect(sale['total_minor'], 12500);
    expect(sale['paid_minor'], 5000);
    expect(sale['customer_id'], isNull);
    final columns = await db.rawQuery('PRAGMA table_info(sales)');
    final customerColumn = columns.singleWhere((row) => row['name'] == 'customer_id');
    expect(customerColumn['notnull'], 0);
    expect((await db.query('schema_migrations', where: 'version = ?', whereArgs: [9])), hasLength(1));

    await createAccountSchema(db);
    expect((await db.query('sales', where: 'id = ?', whereArgs: [saleId])).single['total_minor'], 12500);
    expect(await db.query('customers'), isEmpty);
  });
}
