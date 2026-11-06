import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/application/services/expense_application_service.dart';
import 'package:smart_merchant_suite/application/services/product_application_service.dart';
import 'package:smart_merchant_suite/application/services/sales_application_service.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/expense_repository.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:smart_merchant_suite/domain/sale_return_line.dart';
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

  Future<int> mainBranchId() async =>
      (await database.query('branches', columns: ['id'], where: 'name = ?',
          whereArgs: ['الفرع الرئيسي'], limit: 1)).single['id']! as int;

  Future<int> mainWarehouseId() async =>
      (await WarehouseRepository(database).warehouses()).firstWhere((w) => w.name == 'المخزن الرئيسي').id;


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
      stockQuantity: 4000,
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
      stockQuantity: 4000,
      categoryId: categoryId,
      unitId: unitId,
    ));
    final updated = (await products.all()).single;
    expect(updated.categoryId, categoryId);
    expect(updated.unitId, unitId);
    expect(updated.stockQuantity, 4000);
  });

  test('prevents disabling the default piece unit', () async {
    final catalog = ProductRepository(database);
    final unit = (await catalog.units()).single;
    expect(unit.name, 'قطعة');
    await expectLater(
      catalog.setUnitActive(id: unit.id, isActive: false),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      catalog.updateUnit(
        id: unit.id,
        name: 'حبة',
        abbreviation: 'حبة',
        allowsFraction: false,
      ),
      throwsA(isA<AppException>()),
    );
    final warehouses = WarehouseRepository(database);
    final branch = (await warehouses.branches()).single;
    final warehouse = (await warehouses.warehouses()).single;
    await expectLater(
      warehouses.updateBranch(id: branch.id, name: 'فرع بديل'),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      warehouses.updateWarehouse(id: warehouse.id, name: 'مخزن بديل'),
      throwsA(isA<AppException>()),
    );
  });

  test('keeps independent warehouse balances and transfers stock atomically', () async {
    final warehouseStore = WarehouseRepository(database);
    final branches = await warehouseStore.branches();
    final secondBranchId = await warehouseStore.addBranch(name: 'فرع المدينة');
    final secondWarehouseId = await warehouseStore.addWarehouse(branchId: secondBranchId, name: 'مخزن الفرع');
    final mainWarehouse = (await warehouseStore.warehouses()).firstWhere((warehouse) => warehouse.name == 'المخزن الرئيسي');
    final productId = await products.add(const Product(name: 'صنف متعدد المخازن', costMinor: 100, priceMinor: 150, stockQuantity: 10000));

    await warehouseStore.transferStock(productId: productId, fromWarehouseId: mainWarehouse.id, toWarehouseId: secondWarehouseId, quantity: 4000, reason: 'توزيع مخزون');

    final mainStock = (await warehouseStore.stock(warehouseId: mainWarehouse.id)).singleWhere((row) => row.productId == productId);
    final secondStock = (await warehouseStore.stock(warehouseId: secondWarehouseId)).singleWhere((row) => row.productId == productId);
    expect(mainStock.quantity, 6000);
    expect(secondStock.quantity, 4000);
    expect((await products.all()).single.stockQuantity, 10000);
    final movements = await database.query('inventory_movements', where: 'product_id = ?', whereArgs: [productId], orderBy: 'id ASC');
    expect(movements, hasLength(3));
    expect(movements[1]['quantity_delta'], -4000);
    expect(movements[2]['quantity_delta'], 4000);
    expect(movements[1]['warehouse_id'], mainWarehouse.id);
    expect(movements[2]['warehouse_id'], secondWarehouseId);
    expect(branches.single.name, 'الفرع الرئيسي');
  });

  test('rejects transfer from a warehouse with insufficient stock', () async {
    final warehouseStore = WarehouseRepository(database);
    final branchId = await warehouseStore.addBranch(name: 'فرع آخر');
    final targetId = await warehouseStore.addWarehouse(branchId: branchId, name: 'مخزن آخر');
    final source = (await warehouseStore.warehouses()).firstWhere((warehouse) => warehouse.name == 'المخزن الرئيسي');
    final productId = await products.add(const Product(name: 'مخزون محدود', costMinor: 10, priceMinor: 20, stockQuantity: 2000));
    await expectLater(warehouseStore.transferStock(productId: productId, fromWarehouseId: source.id, toWarehouseId: targetId, quantity: 3000, reason: 'تحويل زائد'), throwsA(isA<AppException>()));
    expect((await products.all()).single.stockQuantity, 2000);
    expect(await database.query('inventory_movements', where: 'product_id = ?', whereArgs: [productId]), hasLength(1));
  });
  test('adjusts stock in a selected warehouse and keeps total product stock accurate', () async {
    final store = WarehouseRepository(database);
    final productId = await products.add(const Product(name: 'سلعة', costMinor: 50, priceMinor: 80, stockQuantity: 3000));
    final branchId = await store.addBranch(name: 'فرع المخزن الإضافي');
    final warehouseId = await store.addWarehouse(branchId: branchId, name: 'المخزن الجانبي');
    await store.adjustStock(warehouseId: warehouseId, productId: productId, quantityDelta: 5000, reason: 'رصيد جرد');
    expect((await store.stock(warehouseId: warehouseId)).single.quantity, 5000);
    expect((await products.all()).single.stockQuantity, 8000);
    expect((await products.all()).single.defaultWarehouseStock, 3000);
    await products.changeStock(productId: productId, quantityDelta: -2000, reason: 'بيع من المخزن الرئيسي');
    expect((await products.all()).single.stockQuantity, 6000);
    expect((await store.stock(warehouseId: warehouseId)).single.quantity, 5000);
    await expectLater(store.adjustStock(warehouseId: warehouseId, productId: productId, quantityDelta: -6000, reason: 'خصم زائد'), throwsA(isA<AppException>()));
    expect((await products.all()).single.stockQuantity, 6000);
  });

  test('scopes product listing and stock adjustment to the selected warehouse', () async {
    final store = WarehouseRepository(database);
    final branchId = await store.addBranch(name: 'فرع سياق النشاط');
    final warehouseId = await store.addWarehouse(
      branchId: branchId,
      name: 'مخزن سياق النشاط',
    );
    final productId = await products.add(const Product(
      name: 'منتج حسب المخزن',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 3000,
    ));

    await products.changeStock(
      productId: productId,
      quantityDelta: 2000,
      reason: 'تسوية في المخزن المحدد',
      warehouseId: warehouseId,
    );

    final selectedWarehouseProduct =
        (await products.all(warehouseId: warehouseId)).single;
    expect(selectedWarehouseProduct.defaultWarehouseStock, 2000);
    expect(selectedWarehouseProduct.stockQuantity, 5000);
    expect(
      (await store.stock(warehouseId: warehouseId))
          .singleWhere((row) => row.productId == productId)
          .quantity,
      2000,
    );
    expect(
      (await store.stock(warehouseId: (await store.warehouses())
              .firstWhere((item) => item.name == 'المخزن الرئيسي').id))
          .singleWhere((row) => row.productId == productId)
          .quantity,
      3000,
    );
  });

  test('prevents deactivating branches or warehouses that still contain active stock', () async {
    final store = WarehouseRepository(database);
    final branchId = await store.addBranch(name: 'فرع تجريبي');
    final warehouseId = await store.addWarehouse(branchId: branchId, name: 'مخزن تجريبي');
    final productId = await products.add(const Product(name: 'منتج مخزن', costMinor: 10, priceMinor: 20, stockQuantity: 2000));
    await store.transferStock(productId: productId, fromWarehouseId: (await store.warehouses()).firstWhere((w) => w.name == 'المخزن الرئيسي').id, toWarehouseId: warehouseId, quantity: 2000, reason: 'نقل للمخزن');
    await expectLater(store.setWarehouseActive(id: warehouseId, isActive: false), throwsA(isA<AppException>()));
    await expectLater(store.setBranchActive(id: branchId, isActive: false), throwsA(isA<AppException>()));
    expect((await products.all()).single.stockQuantity, 2000);
  });
  test('stores money as integer minor units and lists products', () async {
    await products.add(const Product(
      name: '  كابل USB  ',
      sku: 'USB-01',
      costMinor: 1250,
      priceMinor: 2000,
      stockQuantity: 3000,
    ));

    final result = await products.all(search: 'USB');

    expect(result, hasLength(1));
    expect(result.single.name, 'كابل USB');
    expect(result.single.costMinor, 1250);
    expect(result.single.priceMinor, 2000);
    expect(result.single.stockQuantity, 3000);
  });

  test('records an opening stock movement atomically when creating a product', () async {
    final id = await products.add(const Product(
      name: 'دفتر',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 8000,
    ));

    final product = (await products.all()).single;
    final movements = await database.query('inventory_movements');

    expect(product.id, id);
    expect(product.stockQuantity, 8000);
    expect(movements, hasLength(1));
    expect(movements.single['product_id'], id);
    expect(movements.single['quantity_delta'], 8000);
    expect(movements.single['reason'], 'رصيد افتتاحي');
  });

  test('updates product details without changing stock', () async {
    final id = await products.add(const Product(
      name: 'كابل USB',
      sku: 'USB-01',
      costMinor: 1250,
      priceMinor: 2000,
      stockQuantity: 7000,
    ));

    await products.update(Product(
      id: id,
      name: 'كابل USB-C',
      sku: 'USBC-01',
      costMinor: 1500,
      priceMinor: 2500,
      stockQuantity: 7000,
    ));

    final updated = (await products.all()).single;
    expect(updated.name, 'كابل USB-C');
    expect(updated.sku, 'USBC-01');
    expect(updated.costMinor, 1500);
    expect(updated.priceMinor, 2500);
    expect(updated.stockQuantity, 7000);
  });

  test('stock change and movement are recorded together', () async {
    final id = await products.add(const Product(
      name: 'شاحن',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 2000,
    ));

    await products.changeStock(
      productId: id,
      quantityDelta: 4000,
      reason: 'توريد تجريبي',
    );

    expect((await products.all()).single.stockQuantity, 6000);
    final movements = await database.query('inventory_movements');
    expect(movements, hasLength(2));
    expect(movements[0]['quantity_delta'], 2000);
    expect(movements[1]['quantity_delta'], 4000);
  });

  test('rejects stock below zero without writing an additional movement', () async {
    final id = await products.add(const Product(
      name: 'سماعة',
      costMinor: 1000,
      priceMinor: 1500,
      stockQuantity: 1000,
    ));

    await expectLater(
      products.changeStock(
        productId: id,
        quantityDelta: -2000,
        reason: 'اختبار المخزون السالب',
      ),
      throwsA(isA<AppException>()),
    );

    expect((await products.all()).single.stockQuantity, 1000);
    final movements = await database.query('inventory_movements');
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 1000);
  });

  test('deactivates product without deleting stock history', () async {
    final id = await products.add(const Product(
      name: 'شاحن',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 4000,
    ));
    await products.changeStock(
      productId: id,
      quantityDelta: 2000,
      reason: 'توريد',
    );

    await products.setActive(productId: id, isActive: false);

    expect(await products.all(), isEmpty);
    final archived = (await products.all(includeInactive: true)).single;
    expect(archived.isActive, isFalse);
    expect(archived.stockQuantity, 6000);
    expect(await database.query('inventory_movements'), hasLength(2));
    await expectLater(
      products.changeStock(
        productId: id,
        quantityDelta: 1000,
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
      stockQuantity: 5000,
    ));
    final sales = SalesApplicationService(SalesRepository(database));
    final customerId = await AccountRepository(database).addCustomer(name: 'عميل بيع تجريبي');
    final saleId = await sales.createSale(
      quantities: {id: 2000},
      paidMinor: 1000,
      customerId: customerId,
      warehouseId: (await WarehouseRepository(database).warehouses()).first.id,
    );

    expect((await products.all()).single.stockQuantity, 3000);
    expect((await products.all()).single.defaultWarehouseStock, 3000);
    final invoices = await database.query('sales');
    expect(invoices, hasLength(1));
    expect(invoices.single['id'], saleId);
    expect(invoices.single['total_minor'], 1800);
    expect(invoices.single['paid_minor'], 1000);
    expect(invoices.single['warehouse_id'], (await WarehouseRepository(database).warehouses()).first.id);
    final lines = await database.query('sale_items');
    expect(lines, hasLength(1));
    expect(lines.single['unit_cost_minor'], 500);
    final movements = await database.query('inventory_movements', orderBy: 'id ASC');
    expect(movements, hasLength(2));
    expect(movements[0]['quantity_delta'], 5000);
    expect(movements[1]['quantity_delta'], -2000);
  });

  test('supports fractional stock adjustment and warehouse transfer', () async {
    final catalog = ProductRepository(database);
    final unitId = await catalog.addUnit(
      name: 'لتر',
      abbreviation: 'لتر',
      allowsFraction: true,
    );
    final store = WarehouseRepository(database);
    final main = await mainWarehouseId();
    final branchId = await store.addBranch(name: 'فرع السوائل');
    final target = await store.addWarehouse(branchId: branchId, name: 'مخزن السوائل');
    final productId = await products.add(Product(
      name: 'زيت',
      costMinor: 200,
      priceMinor: 300,
      stockQuantity: 1500,
      unitId: unitId,
    ));

    await store.adjustStock(
      warehouseId: target,
      productId: productId,
      quantityDelta: 750,
      reason: 'إضافة ربع لتر وثلاثة أرباع',
    );
    await store.transferStock(
      productId: productId,
      fromWarehouseId: main,
      toWarehouseId: target,
      quantity: 500,
      reason: 'تحويل نصف لتر',
    );

    final mainStock = (await store.stock(warehouseId: main)).singleWhere((row) => row.productId == productId);
    final targetStock = (await store.stock(warehouseId: target)).singleWhere((row) => row.productId == productId);
    expect(mainStock.quantity, 1000);
    expect(targetStock.quantity, 1250);
    expect((await products.all()).single.stockQuantity, 2250);
  });

  test('rejects fractional writes for units configured as whole-only', () async {
    final id = await products.add(const Product(
      name: 'قلم',
      costMinor: 100,
      priceMinor: 150,
      stockQuantity: 2000,
    ));
    final warehouse = await mainWarehouseId();
    final store = WarehouseRepository(database);
    await expectLater(
      products.changeStock(productId: id, quantityDelta: 500, reason: 'اختبار'),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      store.adjustStock(warehouseId: warehouse, productId: id, quantityDelta: 500, reason: 'اختبار'),
      throwsA(isA<AppException>()),
    );
    final branchId = await store.addBranch(name: 'فرع الكميات الصحيحة');
    final target = await store.addWarehouse(branchId: branchId, name: 'مخزن القطع');
    await expectLater(
      store.transferStock(productId: id, fromWarehouseId: warehouse, toWarehouseId: target, quantity: 500, reason: 'اختبار'),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      SalesApplicationService(SalesRepository(database)).createSale(
        quantities: {id: 500},
        paidMinor: 0,
        warehouseId: warehouse,
      ),
      throwsA(isA<AppException>()),
    );
  });

  test('sells a fractional quantity and rounds invoice money in piastres', () async {
    final catalog = ProductRepository(database);
    final unitId = await catalog.addUnit(
      name: 'كيلوجرام',
      abbreviation: 'كجم',
      allowsFraction: true,
    );
    final productId = await products.add(Product(
      name: 'أرز',
      costMinor: 500,
      priceMinor: 1000,
      stockQuantity: 2500,
      unitId: unitId,
    ));
    expect((await products.all()).single.unitAllowsFraction, isTrue);
    await expectLater(
      catalog.updateUnit(id: unitId, name: 'كيلوجرام', abbreviation: 'كجم', allowsFraction: false),
      throwsA(isA<AppException>()),
    );

    final saleId = await SalesApplicationService(SalesRepository(database)).createSale(
      quantities: {productId: 1500},
      paidMinor: 1500,
      warehouseId: await mainWarehouseId(),
    );

    final invoice = (await database.query('sales', where: 'id = ?', whereArgs: [saleId])).single;
    final line = (await database.query('sale_items', where: 'sale_id = ?', whereArgs: [saleId])).single;
    expect(line['quantity'], 1500);
    expect(line['line_total_minor'], 1500);
    expect(invoice['total_minor'], 1500);
    expect((await products.all()).single.stockQuantity, 1000);
    expect((await WarehouseRepository(database).stock(warehouseId: await mainWarehouseId())).single.quantity, 1000);
  });

  test('sale deducts stock only from the selected warehouse', () async {
    final productId = await products.add(const Product(
      name: 'صنف فرع المدينة',
      costMinor: 100,
      priceMinor: 200,
      stockQuantity: 5000,
    ));
    final store = WarehouseRepository(database);
    final branchId = await store.addBranch(name: 'فرع المدينة');
    final otherWarehouseId = await store.addWarehouse(
      branchId: branchId,
      name: 'مخزن البيع',
    );
    await store.transferStock(
      productId: productId,
      fromWarehouseId: await mainWarehouseId(),
      toWarehouseId: otherWarehouseId,
      quantity: 3000,
      reason: 'تجهيز الفرع',
    );

    final sales = SalesApplicationService(SalesRepository(database));
    await sales.createSale(
      quantities: {productId: 2000},
      paidMinor: 400,
      warehouseId: otherWarehouseId,
    );
    final invoice = (await database.query('sales')).single;
    expect(invoice['warehouse_id'], otherWarehouseId);

    final mainId = await mainWarehouseId();
    final mainBalance = (await store.stock(warehouseId: mainId))
        .singleWhere((item) => item.productId == productId);
    final branchBalance = (await store.stock(warehouseId: otherWarehouseId))
        .singleWhere((item) => item.productId == productId);
    expect(mainBalance.quantity, 2000);
    expect(branchBalance.quantity, 1000);
    expect((await products.all()).single.stockQuantity, 3000);
    final lastMovement = (await database.query(
      'inventory_movements',
      where: 'product_id = ?',
      whereArgs: [productId],
      orderBy: 'id DESC',
      limit: 1,
    )).single;
    expect(lastMovement['warehouse_id'], otherWarehouseId);
    expect(lastMovement['quantity_delta'], -2000);
  });

  test('sale rejects insufficient stock without partial invoice', () async {
    final id = await products.add(const Product(
      name: 'سماعة',
      costMinor: 1000,
      priceMinor: 1500,
      stockQuantity: 1000,
    ));
    await expectLater(
      SalesApplicationService(SalesRepository(database)).createSale(
        quantities: {id: 2000},
        paidMinor: 0,
        warehouseId: await mainWarehouseId(),
      ),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('sale_items'), isEmpty);
    expect((await products.all()).single.stockQuantity, 1000);
    expect(await database.query('inventory_movements'), hasLength(1));
  });

  test('creates multi-item invoice and deducts stock for every line', () async {
    final charger = await products.add(const Product(
      name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5000,
    ));
    final headset = await products.add(const Product(
      name: 'سماعة', costMinor: 1000, priceMinor: 1500, stockQuantity: 3000,
    ));

    final sales = SalesApplicationService(SalesRepository(database));
    final customerId = await AccountRepository(database).addCustomer(name: 'عميل فاتورة متعددة');
    final id = await sales.createSale(
      quantities: {charger: 2000, headset: 1000},
      paidMinor: 3000,
      warehouseId: (await WarehouseRepository(database).warehouses()).first.id,
      customerId: customerId,
    );

    expect((await products.all()).firstWhere((p) => p.id == charger).stockQuantity, 3000);
    expect((await products.all()).firstWhere((p) => p.id == headset).stockQuantity, 2000);
    final invoice = (await sales.all()).single;
    expect(invoice.id, id);
    expect(invoice.totalMinor, 3300);
    expect(invoice.paidMinor, 3000);
    expect(invoice.remainingMinor, 300);
    expect(invoice.itemCount, 2);
    expect(invoice.warehouseName, 'المخزن الرئيسي');
    expect(invoice.branchName, 'الفرع الرئيسي');
    expect(await database.query('sale_items'), hasLength(2));
    expect(await database.query('inventory_movements'), hasLength(4));
  });

  test('multi-item sale rolls back all changes if any line has insufficient stock', () async {
    final first = await products.add(const Product(
      name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5000,
    ));
    final second = await products.add(const Product(
      name: 'سماعة', costMinor: 1000, priceMinor: 1500, stockQuantity: 1000,
    ));

    await expectLater(
      SalesApplicationService(SalesRepository(database)).createSale(
        quantities: {first: 2000, second: 2000},
        paidMinor: 0,
        warehouseId: await mainWarehouseId(),
      ),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('sale_items'), isEmpty);
    expect(await database.query('inventory_movements'), hasLength(2));
    expect((await products.all()).firstWhere((p) => p.id == first).stockQuantity, 5000);
    expect((await products.all()).firstWhere((p) => p.id == second).stockQuantity, 1000);
  });

  test('records expenses and calculates all-time profit summary', () async {
    final id = await products.add(const Product(name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5000));
    await SalesApplicationService(SalesRepository(database)).createSale(
      quantities: {id: 2000}, paidMinor: 1800,
      warehouseId: (await WarehouseRepository(database).warehouses()).first.id,
    );
    final expenses = ExpenseApplicationService(ExpenseRepository(database));
    final expenseBranchId = await mainBranchId();
    final cashbook = CashbookRepository(database);
    final expenseDrawerId =
        (await cashbook.ensureDrawer(branchId: expenseBranchId))['id']! as int;
    await cashbook.openSession(
      branchId: expenseBranchId,
      cashDrawerId: expenseDrawerId,
      openingBalanceMinor: 0,
    );
    await expenses.add(
      description: 'إيجار المحل',
      category: 'إيجار',
      amountMinor: 4000,
      branchId: expenseBranchId,
    );
    final branchId = await mainBranchId();
    final s = await expenses.summary(branchId: branchId);
    expect(s.salesMinor, 1800);
    expect(s.costOfGoodsMinor, 1000);
    expect(s.expensesMinor, 4000);
    expect(s.grossProfitMinor, 800);
    expect(s.netProfitMinor, -3200);
    expect((await expenses.all(branchId: branchId)).single.description, 'إيجار المحل');
  });

  test('profit summary subtracts customer return revenue and original inventory cost', () async {
    final id = await products.add(const Product(
      name: 'صنف مرتجع للأرباح',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 5000,
    ));
    final sales = SalesRepository(database);
    final saleId = await sales.createSale(
      quantities: {id: 2000},
      paidMinor: 1800,
      warehouseId: await mainWarehouseId(),
    );
    final saleItemId = (await database.query('sale_items')).single['id']! as int;
    await sales.createCustomerReturn(
      saleId: saleId,
      items: [SaleReturnLineInput(saleItemId: saleItemId, quantity: 1000)],
      refundedMinor: 900,
      reason: 'مرتجع لاختبار الأرباح',
    );

    final summary = await ExpenseRepository(database).summary(branchId: await mainBranchId());
    expect(summary.salesMinor, 900);
    expect(summary.costOfGoodsMinor, 500);
    expect(summary.grossProfitMinor, 400);
  });

  test('profit summary excludes cancelled invoices and their cost of goods', () async {
    final id = await products.add(const Product(
      name: 'صنف فاتورة ملغاة', costMinor: 500, priceMinor: 900, stockQuantity: 5000,
    ));
    final sales = SalesRepository(database);
    final saleId = await sales.createSale(
      quantities: {id: 2000},
      paidMinor: 1800,
      warehouseId: await mainWarehouseId(),
    );
    await sales.cancelSale(
      saleId: saleId,
      refundedMinor: 1800,
      reason: 'إلغاء لاختبار التقرير',
    );
    final summary = await ExpenseRepository(database).summary(branchId: await mainBranchId());
    expect(summary.salesMinor, 0);
    expect(summary.costOfGoodsMinor, 0);
    expect(summary.grossProfitMinor, 0);
  });

  test('filters profit summary and expenses by inclusive calendar dates', () async {
    final id = await products.add(const Product(
      name: 'شاحن', costMinor: 500, priceMinor: 900, stockQuantity: 5000,
    ));
    await SalesApplicationService(SalesRepository(database)).createSale(
      quantities: {id: 2000}, paidMinor: 1800,
      warehouseId: (await WarehouseRepository(database).warehouses()).first.id,
    );
    await database.update('sales', {'created_at': '2025-01-10T12:00:00.000Z'});
    await database.update('sale_items', {'quantity': 2000});
    final expenses = ExpenseApplicationService(ExpenseRepository(database));
    final expenseBranchId = await mainBranchId();
    final cashbook = CashbookRepository(database);
    final expenseDrawerId =
        (await cashbook.ensureDrawer(branchId: expenseBranchId))['id']! as int;
    await cashbook.openSession(
      branchId: expenseBranchId,
      cashDrawerId: expenseDrawerId,
      openingBalanceMinor: 0,
    );
    await expenses.add(
      description: 'مصروف داخل الفترة',
      category: 'أخرى',
      amountMinor: 300,
      branchId: expenseBranchId,
    );
    await expenses.add(description: 'مصروف خارج الفترة', category: 'أخرى', amountMinor: 700, branchId: expenseBranchId);
    await database.update('expenses', {'created_at': '2025-01-10T09:00:00.000Z'},
      where: 'description = ?', whereArgs: ['مصروف داخل الفترة']);
    await database.update('expenses', {'created_at': '2025-01-11T09:00:00.000Z'},
      where: 'description = ?', whereArgs: ['مصروف خارج الفترة']);

    final from = DateTime(2025, 1, 10);
    final to = DateTime(2025, 1, 10);
    final branchId = await mainBranchId();
    final summary = await expenses.summary(branchId: branchId, from: from, to: to);
    expect(summary.salesMinor, 1800);
    expect(summary.costOfGoodsMinor, 1000);
    expect(summary.expensesMinor, 300);
    expect(summary.netProfitMinor, 500);
    final rows = await expenses.all(branchId: branchId, from: from, to: to);
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
      sales.createSale(quantities: const {}, paidMinor: 0, warehouseId: await mainWarehouseId()),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      sales.createSale(quantities: {1: 0}, paidMinor: 0, warehouseId: await mainWarehouseId()),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      sales.createSale(quantities: {1: 1}, paidMinor: -1, warehouseId: await mainWarehouseId()),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('sales'), isEmpty);
  });

  test('expense application service validates entries and date ranges', () async {
    final expenses = ExpenseApplicationService(ExpenseRepository(database));

    await expectLater(
      expenses.add(description: ' ', category: 'أخرى', amountMinor: 100, branchId: await mainBranchId()),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      expenses.add(description: 'قلم', category: 'أخرى', amountMinor: 0, branchId: await mainBranchId()),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      expenses.all(branchId: await mainBranchId(), from: DateTime(2025, 2, 2), to: DateTime(2025, 2, 1)),
      throwsA(isA<AppException>()),
    );
    expect(await database.query('expenses'), isEmpty);
  });
  test('prevents changing a product unit after purchase history exists', () async {
    final catalog = ProductRepository(database);
    final purchaseStore = PurchaseRepository(database);
    final newUnitId = await catalog.addUnit(
      name: 'عبوة',
      abbreviation: 'عبوة',
      allowsFraction: false,
    );
    final productId = await products.add(const Product(
      name: 'منتج تم توريده',
      costMinor: 100,
      priceMinor: 150,
    ));
    final warehouseId = (await WarehouseRepository(database).warehouses()).first.id;
    final supplierId = await purchaseStore.addSupplier(name: 'مورد تجريبي');
    await purchaseStore.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [PurchaseLineInput(
        productId: productId,
        quantity: 2000,
        unitCostMinor: 120,
      )],
      paidMinor: 0,
    );

    final before = (await products.all()).single;
    expect(before.stockQuantity, 2000);
    await expectLater(
      catalog.update(Product(
        id: productId,
        name: before.name,
        costMinor: before.costMinor,
        priceMinor: before.priceMinor,
        stockQuantity: before.stockQuantity,
        unitId: newUnitId,
      )),
      throwsA(isA<AppException>()),
    );
    final after = (await products.all()).single;
    expect(after.unitId, before.unitId);
    expect(after.stockQuantity, before.stockQuantity);
    expect(await database.query('purchase_items'), hasLength(1));
  });

}
