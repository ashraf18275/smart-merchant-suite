import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AccountRepository accounts;
  late ProductRepository products;
  late SalesRepository sales;
  late WarehouseRepository warehouses;
  late int warehouseId;
  late int productId;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    accounts = AccountRepository(db);
    products = ProductRepository(db);
    sales = SalesRepository(db);
    warehouses = WarehouseRepository(db);
    warehouseId = (await warehouses.warehouses()).single.id;
    productId = await products.add(const Product(
      name: 'منتج اختبار',
      costMinor: 700,
      priceMinor: 1500,
      stockQuantity: 5000,
    ));
  });
  tearDown(() async => db.close());

  test('customer credit sale records invoice debt and partial receipt atomically', () async {
    final customerId = await accounts.addCustomer(name: 'عميل آجل');
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 1000,
      warehouseId: warehouseId,
      customerId: customerId,
    );

    final invoice = (await db.query('sales', where: 'id = ?', whereArgs: [saleId])).single;
    expect(invoice['customer_id'], customerId);
    expect(invoice['total_minor'], 3000);
    expect(invoice['paid_minor'], 1000);
    final entries = await db.query('customer_account_entries', orderBy: 'id ASC');
    expect(entries.map((row) => row['amount_minor']), [3000, -1000]);
    expect(entries.map((row) => row['entry_type']), ['sale', 'receipt']);
    expect(entries.every((row) => row['reference_id'] == saleId), isTrue);
    expect(await accounts.customerBalance(customerId), 2000);
    expect((await products.all()).single.stockQuantity, 3000);
  });

  test('cash sale without customer creates no customer ledger', () async {
    await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    final invoice = (await db.query('sales')).single;
    expect(invoice['customer_id'], isNull);
    expect(await db.query('customer_account_entries'), isEmpty);
  });

  test('rejects payment above invoice total without changing stock or ledger', () async {
    final customerId = await accounts.addCustomer(name: 'عميل');
    await expectLater(
      sales.createSale(
        quantities: {productId: 1000},
        paidMinor: 1501,
        warehouseId: warehouseId,
        customerId: customerId,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect(await db.query('customer_account_entries'), isEmpty);
    expect((await products.all()).single.stockQuantity, 5000);
    expect(await db.query('inventory_movements', where: 'reason LIKE ?', whereArgs: ['بيع%']), isEmpty);
  });

  test('rolls back invoice and stock when customer ledger insertion fails', () async {
    final customerId = await accounts.addCustomer(name: 'عميل');
    await db.execute('''
      CREATE TRIGGER reject_customer_sale_entry
      BEFORE INSERT ON customer_account_entries
      WHEN NEW.entry_type = 'sale'
      BEGIN
        SELECT RAISE(ABORT, 'forced ledger failure');
      END
    ''');

    await expectLater(
      sales.createSale(
        quantities: {productId: 1000},
        paidMinor: 0,
        warehouseId: warehouseId,
        customerId: customerId,
      ),
      throwsA(anything),
    );

    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect(await db.query('customer_account_entries'), isEmpty);
    expect((await products.all()).single.stockQuantity, 5000);
    expect(await db.query('inventory_movements', where: 'reason LIKE ?', whereArgs: ['بيع%']), isEmpty);
  });
  test('rejects an empty invoice without writing any records', () async {
    await expectLater(
      sales.createSale(
        quantities: const {},
        paidMinor: 0,
        warehouseId: warehouseId,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect((await products.all()).single.stockQuantity, 5000);
  });

  test('rejects negative payment at the repository boundary', () async {
    await expectLater(
      sales.createSale(
        quantities: {productId: 1000},
        paidMinor: -1,
        warehouseId: warehouseId,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect((await products.all()).single.stockQuantity, 5000);
  });

}
