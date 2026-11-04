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


  test('multiple partial customer returns cannot exceed the original sale line', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 3000,
      warehouseId: warehouseId,
    );
    final saleItemId = (await db.query('sale_items')).single['id']! as int;

    await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
      refundedMinor: 0,
      reason: 'الدفعة الأولى',
    );
    await expectLater(
      sales.createCustomerReturn(
        saleId: saleId,
        items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1001)],
        refundedMinor: 0,
        reason: 'تجاوز المتبقي',
      ),
      throwsA(isA<AppException>()),
    );
    await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
      refundedMinor: 0,
      reason: 'الدفعة الأخيرة',
    );

    expect((await db.query('sale_items')).single['returned_quantity'], 2000);
    expect((await db.query('customer_returns')), hasLength(2));
    expect((await products.all()).single.stockQuantity, 5000);
  });


  test('customer return restores stock using the original sale cost in weighted average', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 3000,
      warehouseId: warehouseId,
    );
    final saleItemId = (await db.query('sale_items')).single['id']! as int;
    await db.update('products', {'cost_minor': 900},
      where: 'id = ?', whereArgs: [productId]);

    final returnId = await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
      refundedMinor: 0,
      reason: 'إرجاع جزء من البضاعة',
    );

    final product = (await products.all()).single;
    expect(product.stockQuantity, 4000);
    expect(product.costMinor, 850);
    final saleLine = (await db.query('sale_items')).single;
    expect(saleLine['returned_cost_minor'], 700);
    final returnLine = (await db.query('customer_return_items',
      where: 'customer_return_id = ?', whereArgs: [returnId])).single;
    expect(returnLine['unit_cost_minor'], 700);
    expect(returnLine['line_cost_minor'], 700);
  });


  test('journals sale receipts, customer refunds and invoice cancellations', () async {
    final customerId = await accounts.addCustomer(name: 'عميل دفتر الصندوق');
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 1500,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    var cash = await db.query('cash_transactions');
    expect(cash, hasLength(1));
    expect(cash.single['direction'], 'in');
    expect(cash.single['amount_minor'], 1500);
    expect((await db.query('audit_events')).single['action'], 'sale_created');

    final saleItemId = (await db.query('sale_items')).single['id']! as int;
    await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
      refundedMinor: 300,
      reason: 'رد جزء من المشتريات',
    );
    cash = await db.query('cash_transactions', orderBy: 'id ASC');
    expect(cash, hasLength(2));
    expect(cash.last['direction'], 'out');
    expect(cash.last['category'], 'customer_return_refund');
    expect(cash.last['amount_minor'], 300);
    expect((await db.query('audit_events')).map((row) => row['action']),
      ['sale_created', 'customer_return_created']);

    // Cancellation is intentionally rejected after a return; verify its own
    // cash and audit entries on a separate untouched invoice.
    final secondSaleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 700,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    await sales.cancelSale(
      saleId: secondSaleId,
      refundedMinor: 500,
      reason: 'إلغاء دون مرتجع سابق',
    );
    cash = await db.query('cash_transactions', orderBy: 'id ASC');
    expect(cash, hasLength(4));
    expect(cash.last['direction'], 'out');
    expect(cash.last['category'], 'sale_cancellation_refund');
    expect(cash.last['amount_minor'], 500);
    expect((await db.query('audit_events')).last['action'], 'sale_cancelled');
  });

  test('cancels customer invoice once, restores stock, reverses ledger and records refund due', () async {
    final customerId = await accounts.addCustomer(name: 'عميل إلغاء');
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 1000,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    final cancellationId = await sales.cancelSale(
      saleId: saleId,
      refundedMinor: 400,
      reason: 'طلب العميل إلغاء الشراء',
    );
    final invoice = (await db.query('sales', where: 'id = ?', whereArgs: [saleId])).single;
    expect(invoice['cancelled_at'], isNotNull);
    expect(invoice['cancellation_reason'], 'طلب العميل إلغاء الشراء');
    final cancellation = (await db.query('sales_cancellations',
      where: 'id = ?', whereArgs: [cancellationId])).single;
    expect(cancellation['total_minor'], 3000);
    expect(cancellation['paid_minor'], 1000);
    expect(cancellation['refunded_minor'], 400);
    expect((await products.all()).single.stockQuantity, 5000);
    final movement = (await db.query('inventory_movements',
      where: 'reason LIKE ?', whereArgs: ['إلغاء فاتورة بيع%'])).single;
    expect(movement['quantity_delta'], 2000);
    expect(movement['warehouse_id'], warehouseId);
    final entries = await db.query('customer_account_entries', orderBy: 'id ASC');
    expect(entries.map((row) => row['entry_type']),
      ['sale', 'receipt', 'sale_cancel', 'receipt_reversal', 'refund_due']);
    expect(entries.map((row) => row['amount_minor']),
      [3000, -1000, -3000, 1000, -600]);
    expect(await accounts.customerBalance(customerId), -600);
    expect((await sales.all()).single.isCancelled, isTrue);
  });

  test('rejects duplicate cancellation without changing stock or ledger', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    await sales.cancelSale(
      saleId: saleId, refundedMinor: 1500, reason: 'إلغاء أول',
    );
    await expectLater(
      sales.cancelSale(
        saleId: saleId, refundedMinor: 0, reason: 'محاولة ثانية',
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('sales_cancellations'), hasLength(1));
    expect((await products.all()).single.stockQuantity, 5000);
    expect(await db.query('inventory_movements',
      where: 'reason LIKE ?', whereArgs: ['إلغاء فاتورة بيع%']), hasLength(1));
  });

  test('rejects cancellation after a customer return to prevent double stock and ledger reversal', () async {
    final customerId = await accounts.addCustomer(name: 'عميل مرتجع');
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 3000,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    final saleItemId = (await db.query('sale_items')).single['id']! as int;
    await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
      refundedMinor: 0,
      reason: 'مرتجع سابق',
    );
    await expectLater(
      sales.cancelSale(
        saleId: saleId, refundedMinor: 0, reason: 'محاولة إلغاء بعد المرتجع',
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('sales_cancellations'), isEmpty);
    expect((await products.all()).single.stockQuantity, 4000);
  });

  test('rejects cancellation refund above amount collected', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1000,
      warehouseId: warehouseId,
    );
    await expectLater(
      sales.cancelSale(
        saleId: saleId, refundedMinor: 1001, reason: 'مبلغ غير صحيح',
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('sales_cancellations'), isEmpty);
    expect((await products.all()).single.stockQuantity, 4000);
  });

  test('rolls back cancellation stock and document when customer ledger reversal fails', () async {
    final customerId = await accounts.addCustomer(name: 'عميل فشل الإلغاء');
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
      customerId: customerId,
    );
    await db.execute('''
      CREATE TRIGGER reject_sale_cancel_entry
      BEFORE INSERT ON customer_account_entries
      WHEN NEW.entry_type = 'sale_cancel'
      BEGIN
        SELECT RAISE(ABORT, 'forced cancellation ledger failure');
      END
    ''');
    await expectLater(
      sales.cancelSale(
        saleId: saleId, refundedMinor: 1500, reason: 'اختبار التراجع',
      ),
      throwsA(anything),
    );
    expect(await db.query('sales_cancellations'), isEmpty);
    expect((await db.query('sales')).single['cancelled_at'], isNull);
    expect((await products.all()).single.stockQuantity, 4000);
    expect(await db.query('inventory_movements',
      where: 'reason LIKE ?', whereArgs: ['إلغاء فاتورة بيع%']), isEmpty);
    expect(await accounts.customerBalance(customerId), 0);
  });

  test('does not expose cancelled invoices as returnable and rejects direct return attempts', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    final saleItemId = (await db.query('sale_items')).single['id']! as int;
    await sales.cancelSale(
      saleId: saleId, refundedMinor: 1500, reason: 'إلغاء قبل المرتجع',
    );
    expect(await sales.returnableSales(), isEmpty);
    await expectLater(
      sales.createCustomerReturn(
        saleId: saleId,
        items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
        refundedMinor: 0,
        reason: 'محاولة مرتجع بعد الإلغاء',
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('customer_returns'), isEmpty);
    expect((await products.all()).single.stockQuantity, 5000);
  });

  test('cancels cash sale and stores refund without creating customer ledger entries', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 1000},
      paidMinor: 1500,
      warehouseId: warehouseId,
    );
    await sales.cancelSale(
      saleId: saleId,
      refundedMinor: 1000,
      reason: 'رد جزء من المبلغ',
    );
    expect(await db.query('customer_account_entries'), isEmpty);
    expect((await db.query('sales_cancellations')).single['refunded_minor'], 1000);
    expect((await products.all()).single.stockQuantity, 5000);
  });

  test('cancellation restores inventory at the original sale cost', () async {
    final saleId = await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 3000,
      warehouseId: warehouseId,
    );
    await db.update('products', {'cost_minor': 900},
      where: 'id = ?', whereArgs: [productId]);
    await sales.cancelSale(
      saleId: saleId, refundedMinor: 0, reason: 'إلغاء بعد تغير التكلفة',
    );
    final product = (await products.all()).single;
    expect(product.stockQuantity, 5000);
    expect(product.costMinor, 820);
  });


}
