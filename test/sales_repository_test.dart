import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:smart_merchant_suite/domain/sale_return_line.dart';
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


  test('customer return restores stock and posts return and cash refund to customer ledger', () async {
    final customerId = await accounts.addCustomer(name: 'عميل مرتجع');
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 1000,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    final saleItem = (await db.query('sale_items', where: 'sale_id = ?', whereArgs: [saleId])).single;

    final returnId = await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItem['id']! as int, quantity: 1000)],
      refundedMinor: 500,
      reason: 'جزء تالف',
    );

    final document = (await db.query('customer_returns', where: 'id = ?', whereArgs: [returnId])).single;
    expect(document['total_minor'], 1500);
    expect(document['refunded_minor'], 500);
    expect((await db.query('sale_items')).single['returned_quantity'], 1000);
    expect((await db.query('sale_items')).single['returned_minor'], 1500);
    expect((await products.all()).single.stockQuantity, 4000);
    final movement = (await db.query('inventory_movements', where: 'reason LIKE ?', whereArgs: ['مرتجع بيع%'])).single;
    expect(movement['quantity_delta'], 1000);
    expect(movement['warehouse_id'], warehouseId);
    final entries = await db.query('customer_account_entries', orderBy: 'id ASC');
    expect(entries.map((row) => row['entry_type']), ['sale', 'receipt', 'return', 'refund']);
    expect(entries.map((row) => row['amount_minor']), [3000, -1000, -1500, 500]);
    expect(await accounts.customerBalance(customerId), 1000);
  });

  test('rejects customer return quantities above the remaining sold quantity', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    final saleItem = (await db.query('sale_items')).single;
    await expectLater(
      sales.createCustomerReturn(
        saleId: saleId,
        items: [SaleReturnLineInput(saleItemId: saleItem['id']! as int, quantity: 1001)],
        refundedMinor: 0,
        reason: 'اختبار تجاوز الكمية',
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('customer_returns'), isEmpty);
    expect((await db.query('sale_items')).single['returned_quantity'], 0);
    expect((await products.all()).single.stockQuantity, 4000);
  });

  test('rejects cash refund above the returned goods value', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    final saleItem = (await db.query('sale_items')).single;
    await expectLater(
      sales.createCustomerReturn(
        saleId: saleId,
        items: [SaleReturnLineInput(saleItemId: saleItem['id']! as int, quantity: 1000)],
        refundedMinor: 1501,
        reason: 'اختبار مبلغ الاسترداد',
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('customer_returns'), isEmpty);
    expect((await products.all()).single.stockQuantity, 4000);
  });

  test('rolls back customer return, stock and ledger when customer ledger write fails', () async {
    final customerId = await accounts.addCustomer(name: 'عميل فشل المرتجع');
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 0,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    final saleItem = (await db.query('sale_items')).single;
    await db.execute('''
      CREATE TRIGGER reject_customer_return_entry
      BEFORE INSERT ON customer_account_entries
      WHEN NEW.entry_type = 'return'
      BEGIN
        SELECT RAISE(ABORT, 'forced return ledger failure');
      END
    ''');

    await expectLater(
      sales.createCustomerReturn(
        saleId: saleId,
        items: [SaleReturnLineInput(saleItemId: saleItem['id']! as int, quantity: 1000)],
        refundedMinor: 0,
        reason: 'اختبار التراجع',
      ),
      throwsA(anything),
    );
    expect(await db.query('customer_returns'), isEmpty);
    expect(await db.query('customer_return_items'), isEmpty);
    expect((await db.query('sale_items')).single['returned_quantity'], 0);
    expect((await products.all()).single.stockQuantity, 4000);
    expect(await db.query('inventory_movements', where: 'reason LIKE ?', whereArgs: ['مرتجع بيع%']), isEmpty);
    expect(await accounts.customerBalance(customerId), 1500);
  });

  test('cash sale can be returned without creating a customer ledger', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    final saleItem = (await db.query('sale_items')).single;
    await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItem['id']! as int, quantity: 1000)],
      refundedMinor: 1500,
      reason: 'إرجاع بيع نقدي',
    );
    expect((await products.all()).single.stockQuantity, 5000);
    expect(await db.query('customer_account_entries'), isEmpty);
    expect((await db.query('customer_returns')).single['refunded_minor'], 1500);
  });

}
