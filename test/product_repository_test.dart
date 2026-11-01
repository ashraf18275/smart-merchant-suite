import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/application/services/expense_application_service.dart';
import 'package:smart_merchant_suite/application/services/product_application_service.dart';
import 'package:smart_merchant_suite/application/services/sales_application_service.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/data/expense_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late ProductApplicationService products;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    products = ProductApplicationService(ProductRepository(database));
  });

  tearDown(() async {
    await database.close();
  });


  test('manages categories and units without deleting historical references', () async {
    final catalog = ProductRepository(database);
    final categoryId = await catalog.addCategory('مشروبات');
    final unitId = await catalog.addUnit(
      name: 'زجاجة',
      abbreviation: 'زجاجة',
      allowsFraction: false,
    );
    final productId = await products.add(Product(
      name: 'مياه',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 4,
      categoryId: categoryId,
      unitId: unitId,
    ));

    await catalog.updateCategory(id: categoryId, name: 'مشروبات باردة');
    await catalog.updateUnit(
      id: unitId,
      name: 'عبوة',
      abbreviation: 'عبوة',
      allowsFraction: false,
    );
    await catalog.setCategoryActive(id: categoryId, isActive: false);
    await catalog.setUnitActive(id: unitId, isActive: false);

    final saved = (await products.all()).single;
    expect(saved.categoryId, categoryId);
    expect(saved.unitId, unitId);
    expect((await catalog.categories(includeInactive: true)).single.name, 'مشروبات باردة');
    expect((await catalog.units(includeInactive: true)).firstWhere((u) => u.id == unitId).name, 'عبوة');
    expect(await catalog.categories(), isEmpty);
    expect((await catalog.units()).map((u) => u.name), contains('قطعة'));

    await products.update(Product(
      id: productId,
      name: 'مياه معدنية',
      costMinor: 110,
      priceMinor: 160,
      stockQuantity: 4,
      categoryId: categoryId,
      unitId: unitId,
    ));
    final updated = (await products.all()).single;
    expect(updated.categoryId, categoryId);
    expect(updated.unitId, unitId);
    expect(updated.stockQuantity, 4);
  });

  test('prevents disabling the default piece unit', () async {
    final catalog = ProductRepository(database);
    final unit = (await catalog.units()).single;
    expect(unit.name, 'قطعة');
    await expectLater(
      catalog.setUnitActive(id: unit.id, isActive: false),
      throwsA(isA<AppException>()),
    );
  });

  test('keeps independent warehouse balances and transfers stock atomically', () async {
    final warehouseStore = WarehouseRepository(database);
    final branches = await warehouseStore.branches();
    final secondBranchId = await warehouseStore.addBranch(name: 'فرع المدينة');
    final secondWarehouseId = await warehouseStore.addWarehouse(branchId: secondBranchId, name: 'مخزن الفرع');
    final mainWarehouse = (await warehouseStore.warehouses()).firstWhere((warehouse) => warehouse.name == 'المخزن الرئيسي');
    final productId = await products.add(const Product(name: 'صنف متعدد المخازن', costMinor: 100, priceMinor: 150, stockQuantity: 10));

    await warehouseStore.transferStock(productId: productId, fromWarehouseId: mainWarehouse.id, toWarehouseId: secondWarehouseId, quantity: 4, reason: 'توزيع مخزون');

    final mainStock = (await warehouseStore.stock(warehouseId: mainWarehouse.id)).singleWhere((row) => row.productId == productId);
    final secondStock = (await warehouseStore.stock(warehouseId: secondWarehouseId)).singleWhere((row) => row.productId == productId);
    expect(mainStock.quantity, 6);
    expect(secondStock.quantity, 4);
    expect((await products.all()).single.stockQuantity, 10);
    final movements = await database.query('inventory_movements', where: 'product_id = ?', whereArgs: [productId], orderBy: 'id ASC');
    expect(movements, hasLength(3));
    expect(movements[1]['quantity_delta'], -4);
    expect(movements[2]['quantity_delta'], 4);
    expect(movements[1]['warehouse_id'], mainWarehouse.id);
    expect(movements[2]['warehouse_id'], secondWarehouseId);
    expect(branches.single.name, 'الفرع الرئيسي');
  });

  test('rejects transfer from a warehouse with insufficient stock', () async {
    final warehouseStore = WarehouseRepository(database);
    final branchId = await warehouseStore.addBranch(name: 'فرع آخر');
    final targetId = await warehouseStore.addWarehouse(branchId: branchId, name: 'مخزن آخر');
    final source = (await warehouseStore.warehouses()).firstWhere((warehouse) => warehouse.name == 'المخزن الرئيسي');
    final productId = await products.add(const Product(name: 'مخزون محدود', costMinor: 10, priceMinor: 20, stockQuantity: 2));
    await expectLater(warehouseStore.transferStock(productId: productId, fromWarehouseId: source.id, toWarehouseId: targetId, quantity: 3, reason: 'تحويل زائد'), throwsA(isA<AppException>()));
    expect((await products.all()).single.stockQuantity, 2);
    expect(await database.query('inventory_movements', where: 'product_id = ?', whereArgs: [productId]), hasLength(1));
  });
  test('adjusts stock in a selected warehouse and keeps total product stock accurate', () async {
    final store = WarehouseRepository(database);
    final productId = await products.add(const Product(name: 'سلعة', costMinor: 50, priceMinor: 80, stockQuantity: 3));
    final branchId = await store.addBranch(name: 'فرع المخزن الإضافي');
    final warehouseId = await store.addWarehouse(branchId: branchId, name: 'المخزن الجانبي');
    await store.adjustStock(warehouseId: warehouseId, productId: productId, quantityDelta: 5, reason: 'رصيد جرد');
    expect((await store.stock(warehouseId: warehouseId)).single.quantity, 5);
    expect((await products.all()).single.stockQuantity, 8);
    expect((await products.all()).single.defaultWarehouseStock, 3);
    await products.changeStock(productId: productId, quantityDelta: -2, reason: 'بيع من المخزن الرئيسي');
    expect((await products.all()).single.stockQuantity, 6);
    expect((await store.stock(warehouseId: warehouseId)).single.quantity, 5);
    await expectLater(store.adjustStock(warehouseId: warehouseId, productId: productId, quantityDelta: -6, reason: 'خصم زائد'), throwsA(isA<AppException>()));
    expect((await products.all()).single.stockQuantity, 6);
  });

  test('prevents deactivating branches or warehouses that still contain active stock', () async {
    final store = WarehouseRepository(database);
    final branchId = await store.addBranch(name: 'فرع تجريبي');
    final warehouseId = await store.addWarehouse(branchId: branchId, name: 'مخزن تجريبي');
    final productId = await products.add(const Product(name: 'منتج مخزن', costMinor: 10, priceMinor: 20, stockQuantity: 2));
    await store.transferStock(productId: productId, fromWarehouseId: (await store.warehouses()).firstWhere((w) => w.name == 'المخزن الرئيسي').id, toWarehouseId: warehouseId, quantity: 2, reason: 'نقل للمخزن');
    await expectLater(store.setWarehouseActive(id: warehouseId, isActive: false), throwsA(isA<AppException>()));
    await expectLater(store.setBranchActive(id: branchId, isActive: false), throwsA(isA<AppException>()));
    expect((await products.all()).single.stockQuantity, 2);
  });
  test('stores money as integer minor units and lists products', () async {
    await products.add(const Product(
      name: '  كابل USB  ',
      sku: 'USB-01',
      costMinor: 1250,
      priceMinor: 2000,
      stockQuantity: 3,
    ));

    final result = await products.all(search: 'USB');

    expect(result, hasLength(1));
    expect(result.single.name, 'كابل USB');
    expect(result.single.costMinor, 1250);
    expect(result.single.priceMinor, 2000);
    expect(result.single.stockQuantity, 3);
  });

  test('records an opening stock movement atomically when creating a product', () async {
    final id = await products.add(const Product(
      name: 'دفتر',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 8,
    ));

    final product = (await products.all()).single;
    final movements = await database.query('inventory_movements');

    expect(product.id, id);
    expect(product.stockQuantity, 8);
    expect(movements, hasLength(1));
    expect(movements.single['product_id'], id);
    expect(movements.single['quantity_delta'], 8);
    expect(movements.single['reason'], 'رصيد افتتاحي');
  });

  test('updates product details without changing stock', () async {
    final id = await products.add(const Product(
      name: 'كابل USB',
      sku: 'USB-01',
      costMinor: 1250,
      priceMinor: 2000,
      stockQuantity: 7,
    ));

    await products.update(Product(
      id: id,
      name: 'كابل USB-C',
      sku: 'USBC-01',
      costMinor: 1500,
      priceMinor: 2500,
      stockQuantity: 7,
    ));

    final updated = (await products.all()).single;
    expect(updated.name, 'كابل USB-C');
    expect(updated.sku, 'USBC-01');
    expect(updated.costMinor, 1500);
    expect(updated.priceMinor, 2500);
    expect(updated.stockQuantity, 7);
  });

  test('stock change and movement are recorded together', () async {
    final id = await products.add(const Product(
      name: 'شاحن',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 2,
    ));

    await products.changeStock(
      productId: id,
      quantityDelta: 4,
      reason: 'توريد تجريبي',
    );

    expect((await products.all()).single.stockQuantity, 6);
    final movements = await database.query('inventory_movements');
    expect(movements, hasLength(2));
    expect(movements[0]['quantity_delta'], 2);
    expect(movements[1]['quantity_delta'], 4);
  });

  test('rejects stock below zero without writing an additional movement', () async {
    final id = await products.add(const Product(
      name: 'سماعة',
      costMinor: 1000,
      priceMinor: 1500,
      stockQuantity: 1,
    ));

    await expectLater(
      products.changeStock(
        productId: id,
        quantityDelta: -2,
        reason: 'اختبار المخزون السالب',
      ),
      throwsA(isA<AppException>()),
    );

    expect((await products.all()).single.stockQuantity, 1);
    final movements = await database.query('inventory_movements');
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 1);
  });

  test('deactivates product without deleting stock history', () async {
    final id = await products.add(const Product(
      name: 'شاحن',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 4,
    ));
    await products.changeStock(
      productId: id,
      quantityDelta: 2,
      reason: 'توريد',
    );

    await products.setActive(productId: id, isActive: false);

    expect(await products.all(), isEmpty);
    final archived = (await products.all(includeInactive: true)).single;
    expect(archived.isActive, isFalse);
    expect(archived.stockQuantity, 6);
    expect(await database.query('inventory_movements'), hasLength(2));
    await expectLater(
      products.changeStock(
        productId: id,
        quantityDelta: 1,
        reason: 'محاولة بعد الإيقاف',
      ),
      throwsA(isA<AppException>()),
    );

    await products.setActive(productId: id, isActive: true);
    expect((await products.all()).single.isActive, isTrue);
  });

  test('sale atomically records invoice and deducts stock', () async {
    final id = await products.add(const Product(
      name: 'شاحن',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 5,
    ));
    final sales = SalesApplicationService(SalesRepository(database));
    final saleId = await sales.createSale(
      quantities: {id: 2},
      paidMinor: 1000,
    );

    expect((await products.all()).single.stockQuantity, 3);
    expect((await products.all()).single.defaultWarehouseStock, 3);
    final invoices = await database.query('sales');
    expect(invoices, hasLength(1));
    expect(invoices.single['id'], saleId);
    expect(invoices.single['total_minor'], 1800);
    expect(invoices.single['paid_minor'], 1000);
    final lines = await database.query('sale_items');
    expect(lines, hasLength(1));
    expect(lines.single['unit_cost_minor'], 500);
    final movements = await database.query('inventory_movements', orderBy: 'id ASC');
    expect(movements, hasLength(2));
    expect(movements[0]['quantity_delta'], 5);
    expect(movements[1]['quantity_delta'], -2);
  });

  test('sale rejects insufficient stock without partial invoice', () async {
    final id = await products.add(const Product(
      name: 'سماعة',
      costMinor: 1000,
      priceMinor: 1500,
      stockQuantity: 1,
    ));
    await expectLater(
      SalesApplicationService(SalesRepository(database)).createSale(
        quantities: {id: 2},
        paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('sale_items'), isEmpty);
    expect((await products.all()).single.stockQuantity, 1);
    expect(await database.query('inventory_movements'), hasLength(1));
  });

  test('creates multi-item invoice and deducts stock for every line', () async {
    final charger = await products.add(const Product(
      name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5,
    ));
    final headset = await products.add(const Product(
      name: 'سماعة', costMinor: 1000, priceMinor: 1500, stockQuantity: 3,
    ));

    final sales = SalesApplicationService(SalesRepository(database));
    final id = await sales.createSale(
      quantities: {charger: 2, headset: 1},
      paidMinor: 3000,
    );

    expect((await products.all()).firstWhere((p) => p.id == charger).stockQuantity, 3);
    expect((await products.all()).firstWhere((p) => p.id == headset).stockQuantity, 2);
    final invoice = (await sales.all()).single;
    expect(invoice.id, id);
    expect(invoice.totalMinor, 3300);
    expect(invoice.paidMinor, 3000);
    expect(invoice.remainingMinor, 300);
    expect(invoice.itemCount, 2);
    expect(await database.query('sale_items'), hasLength(2));
    expect(await database.query('inventory_movements'), hasLength(4));
  });

  test('multi-item sale rolls back all changes if any line has insufficient stock', () async {
    final first = await products.add(const Product(
      name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5,
    ));
    final second = await products.add(const Product(
      name: 'سماعة', costMinor: 1000, priceMinor: 1500, stockQuantity: 1,
    ));

    await expectLater(
      SalesApplicationService(SalesRepository(database)).createSale(
        quantities: {first: 2, second: 2},
        paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('sale_items'), isEmpty);
    expect(await database.query('inventory_movements'), hasLength(2));
    expect((await products.all()).firstWhere((p) => p.id == first).stockQuantity, 5);
    expect((await products.all()).firstWhere((p) => p.id == second).stockQuantity, 1);
  });

  test('records expenses and calculates all-time profit summary', () async {
    final id = await products.add(const Product(name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5));
    await SalesApplicationService(SalesRepository(database)).createSale(
      quantities: {id: 2}, paidMinor: 1800,
    );
    final expenses = ExpenseApplicationService(ExpenseRepository(database));
    await expenses.add(description: 'إيجار المحل', category: 'إيجار', amountMinor: 4000);
    final s = await expenses.summary();
    expect(s.salesMinor, 1800);
    expect(s.costOfGoodsMinor, 1000);
    expect(s.expensesMinor, 4000);
    expect(s.grossProfitMinor, 800);
    expect(s.netProfitMinor, -3200);
    expect((await expenses.all()).single.description, 'إيجار المحل');
  });

  test('filters profit summary and expenses by inclusive calendar dates', () async {
    final id = await products.add(const Product(
      name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5,
    ));
    await SalesApplicationService(SalesRepository(database)).createSale(
      quantities: {id: 2}, paidMinor: 1800,
    );
    await database.update('sales', {'created_at': '2025-01-10T12:00:00.000Z'});
    await database.update('sale_items', {'quantity': 2});
    final expenses = ExpenseApplicationService(ExpenseRepository(database));
    await expenses.add(description: 'مصروف داخل الفترة', category: 'أخرى', amountMinor: 300);
    await expenses.add(description: 'مصروف خارج الفترة', category: 'أخرى', amountMinor: 700);
    await database.update('expenses', {'created_at': '2025-01-10T09:00:00.000Z'},
      where: 'description = ?', whereArgs: ['مصروف داخل الفترة']);
    await database.update('expenses', {'created_at': '2025-01-11T09:00:00.000Z'},
      where: 'description = ?', whereArgs: ['مصروف خارج الفترة']);

    final from = DateTime(2025, 1, 10);
    final to = DateTime(2025, 1, 10);
    final summary = await expenses.summary(from: from, to: to);
    expect(summary.salesMinor, 1800);
    expect(summary.costOfGoodsMinor, 1000);
    expect(summary.expensesMinor, 300);
    expect(summary.netProfitMinor, 500);
    final rows = await expenses.all(from: from, to: to);
    expect(rows, hasLength(1));
    expect(rows.single.description, 'مصروف داخل الفترة');
  });

  test('rejects empty product names', () async {
    await expectLater(
      products.add(const Product(
        name: '   ',
        costMinor: 0,
        priceMinor: 100,
      )),
      throwsA(isA<AppException>()),
    );
  });

  test('sales application service rejects an empty or invalid request', () async {
    final sales = SalesApplicationService(SalesRepository(database));

    await expectLater(
      sales.createSale(quantities: const {}, paidMinor: 0),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      sales.createSale(quantities: {1: 0}, paidMinor: 0),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      sales.createSale(quantities: {1: 1}, paidMinor: -1),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('sales'), isEmpty);
  });

  test('expense application service validates entries and date ranges', () async {
    final expenses = ExpenseApplicationService(ExpenseRepository(database));

    await expectLater(
      expenses.add(description: ' ', category: 'أخرى', amountMinor: 100),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      expenses.add(description: 'قلم', category: 'أخرى', amountMinor: 0),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      expenses.all(from: DateTime(2025, 2, 2), to: DateTime(2025, 2, 1)),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('expenses'), isEmpty);
  });
}
