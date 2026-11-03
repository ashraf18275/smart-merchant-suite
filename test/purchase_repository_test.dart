import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ProductRepository products;
  late PurchaseRepository purchases;
  late WarehouseRepository warehouses;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    products = ProductRepository(db);
    purchases = PurchaseRepository(db);
    warehouses = WarehouseRepository(db);
  });
  tearDown(() async => db.close());

  test('receives purchase atomically and updates moving weighted average cost', () async {
    final productId = await products.add(const Product(
      name: 'أرز', costMinor: 1000, priceMinor: 1500, stockQuantity: 2000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد الحبوب');
    final warehouseId = (await warehouses.warehouses()).single.id;

    final purchaseId = await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: const [PurchaseLineInput(productId: 1, quantity: 3000, unitCostMinor: 2000)],
      paidMinor: 3000,
    );

    final product = (await products.all()).single;
    expect(product.id, productId);
    expect(product.stockQuantity, 5000);
    expect(product.costMinor, 1600);
    final purchase = (await db.query('purchases')).single;
    expect(purchase['id'], purchaseId);
    expect(purchase['total_minor'], 6000);
    expect(purchase['paid_minor'], 3000);
    final supplierEntries = await db.query('supplier_account_entries', orderBy: 'id ASC');
    expect(supplierEntries.map((row) => row['amount_minor']), [6000, -3000]);
    expect(supplierEntries.map((row) => row['entry_type']), ['purchase', 'payment']);
    final line = (await db.query('purchase_items')).single;
    expect(line['quantity'], 3000);
    expect(line['unit_cost_minor'], 2000);
    final movement = (await db.query('inventory_movements', orderBy: 'id DESC')).first;
    expect(movement['quantity_delta'], 3000);
    expect(movement['reason'], 'استلام مشتريات رقم $purchaseId');
  });

  test('uses zero received balance as the starting weighted average', () async {
    final productId = await products.add(const Product(
      name: 'زيت', costMinor: 900, priceMinor: 1200,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد الزيوت');
    final warehouseId = (await warehouses.warehouses()).single.id;
    await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [PurchaseLineInput(productId: productId, quantity: 1000, unitCostMinor: 1250)],
      paidMinor: 0,
    );
    final product = (await products.all()).single;
    expect(product.stockQuantity, 1000);
    expect(product.costMinor, 1250);
  });

  test('rejects invalid purchase without changing stock or creating a document', () async {
    final productId = await products.add(const Product(
      name: 'سكر', costMinor: 500, priceMinor: 700,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد السكر');
    final warehouseId = (await warehouses.warehouses()).single.id;
    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [PurchaseLineInput(productId: productId, quantity: 0, unitCostMinor: 500)],
        paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );
    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect((await products.all()).single.stockQuantity, 0);
  });

  test('recalculates weighted average using remaining stock after a sale', () async {
    final productId = await products.add(const Product(
      name: 'منتج بعد البيع',
      costMinor: 1000,
      priceMinor: 2000,
      stockQuantity: 2000,
    ));
    final supplierId = await purchases.addSupplier(name: 'المورد الثاني');
    final warehouseId = (await warehouses.warehouses()).single.id;

    await SalesRepository(db).createSale(
      quantities: {productId: 1000},
      paidMinor: 0,
      warehouseId: warehouseId,
    );
    await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [PurchaseLineInput(
        productId: productId,
        quantity: 1000,
        unitCostMinor: 2000,
      )],
      paidMinor: 0,
    );

    final product = (await products.all()).single;
    expect(product.stockQuantity, 2000);
    expect(product.costMinor, 1500);
    final soldLine = (await db.query('sale_items')).single;
    expect(soldLine['unit_cost_minor'], 1000);
    final receivedLine = (await db.query('purchase_items')).single;
    expect(receivedLine['unit_cost_minor'], 2000);
  });

  test('receives purchase into selected warehouse without changing other warehouse balance', () async {
    final productId = await products.add(const Product(
      name: 'منتج متعدد المخازن',
      costMinor: 1000,
      priceMinor: 1500,
      stockQuantity: 2000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد الفروع');
    final mainWarehouseId = (await warehouses.warehouses()).single.id;
    final branchId = await warehouses.addBranch(name: 'فرع الاختبار');
    final targetWarehouseId = await warehouses.addWarehouse(
      branchId: branchId,
      name: 'مخزن الفرع',
    );

    await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: targetWarehouseId,
      items: [PurchaseLineInput(
        productId: productId,
        quantity: 3000,
        unitCostMinor: 2000,
      )],
      paidMinor: 0,
    );

    final mainStock = (await warehouses.stock(warehouseId: mainWarehouseId))
        .singleWhere((row) => row.productId == productId);
    final targetStock = (await warehouses.stock(warehouseId: targetWarehouseId))
        .singleWhere((row) => row.productId == productId);
    expect(mainStock.quantity, 2000);
    expect(targetStock.quantity, 3000);
    expect((await products.all()).single.stockQuantity, 5000);
    expect((await products.all()).single.costMinor, 1600);
    final movement = (await db.query(
      'inventory_movements',
      where: 'product_id = ?',
      whereArgs: [productId],
      orderBy: 'id DESC',
      limit: 1,
    )).single;
    expect(movement['warehouse_id'], targetWarehouseId);
    expect(movement['quantity_delta'], 3000);
  });

  test('rejects purchase payment above total without writing any records', () async {
    final productId = await products.add(const Product(
      name: 'منتج مدفوع زائد',
      costMinor: 700,
      priceMinor: 1000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد المدفوع الزائد');
    final warehouseId = (await warehouses.warehouses()).single.id;

    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [PurchaseLineInput(
          productId: productId,
          quantity: 1000,
          unitCostMinor: 1000,
        )],
        paidMinor: 1001,
      ),
      throwsA(isA<AppException>()),
    );

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await db.query('supplier_account_entries'), isEmpty);
    expect(await db.query('inventory_movements'), isEmpty);
    final product = (await products.all()).single;
    expect(product.stockQuantity, 0);
    expect(product.costMinor, 700);
  });

  test('rolls back purchase and stock when supplier ledger write fails', () async {
    final productId = await products.add(const Product(
      name: 'منتج فشل القيد',
      costMinor: 700,
      priceMinor: 1000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد فشل القيد');
    final warehouseId = (await warehouses.warehouses()).single.id;
    await db.execute('''
      CREATE TRIGGER reject_supplier_ledger_insert
      BEFORE INSERT ON supplier_account_entries
      BEGIN
        SELECT RAISE(ABORT, 'forced supplier ledger failure');
      END
    ''');

    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [PurchaseLineInput(
          productId: productId,
          quantity: 2000,
          unitCostMinor: 500,
        )],
        paidMinor: 0,
      ),
      throwsA(anything),
    );

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await db.query('supplier_account_entries'), isEmpty);
    expect(await db.query('inventory_movements'), isEmpty);
    final product = (await products.all()).single;
    expect(product.stockQuantity, 0);
    expect(product.costMinor, 700);
    final warehouseStock = (await warehouses.stock(warehouseId: warehouseId))
        .singleWhere((row) => row.productId == productId);
    expect(warehouseStock.quantity, 0);
  });


  test('rolls back the entire purchase when inventory movement fails after stock updates', () async {
    final productId = await products.add(const Product(
      name: 'منتج فشل حركة المخزون',
      costMinor: 700,
      priceMinor: 1000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد فشل حركة المخزون');
    final warehouseId = (await warehouses.warehouses()).single.id;
    await db.execute('''
      CREATE TRIGGER reject_inventory_movement_insert
      BEFORE INSERT ON inventory_movements
      BEGIN
        SELECT RAISE(ABORT, 'forced inventory movement failure');
      END
    ''');

    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [PurchaseLineInput(
          productId: productId,
          quantity: 2000,
          unitCostMinor: 500,
        )],
        paidMinor: 500,
      ),
      throwsA(anything),
    );

    // The failure is deliberately late: document, supplier ledger, purchase
    // line, warehouse balance and product aggregate were already written
    // inside the transaction and must all be rolled back together.
    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await db.query('supplier_account_entries'), isEmpty);
    expect(await db.query('inventory_movements'), isEmpty);
    final product = (await products.all()).single;
    expect(product.stockQuantity, 0);
    expect(product.costMinor, 700);
    final warehouseStock = (await warehouses.stock(warehouseId: warehouseId))
        .singleWhere((row) => row.productId == productId);
    expect(warehouseStock.quantity, 0);
  });


  test('uses summed warehouse balances rather than a stale product aggregate for cost', () async {
    final productId = await products.add(const Product(
      name: 'منتج إجمالي مخزون غير متطابق',
      costMinor: 1000,
      priceMinor: 1500,
      stockQuantity: 2000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد اختبار الاتساق');
    final mainWarehouseId = (await warehouses.warehouses()).single.id;
    final branchId = await warehouses.addBranch(name: 'فرع اختبار الاتساق');
    final branchWarehouseId = await warehouses.addWarehouse(
      branchId: branchId,
      name: 'مخزن اختبار الاتساق',
    );

    // Simulate a stale denormalized total. Warehouse balances remain canonical.
    await db.update(
      'products',
      {'stock_quantity': 9000},
      where: 'id = ?',
      whereArgs: [productId],
    );

    await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: branchWarehouseId,
      items: [PurchaseLineInput(
        productId: productId,
        quantity: 1000,
        unitCostMinor: 2000,
      )],
      paidMinor: 0,
    );

    final product = (await products.all()).single;
    expect(product.stockQuantity, 3000);
    expect(product.costMinor, 1333);
    final mainStock = (await warehouses.stock(warehouseId: mainWarehouseId))
        .singleWhere((row) => row.productId == productId);
    final branchStock = (await warehouses.stock(warehouseId: branchWarehouseId))
        .singleWhere((row) => row.productId == productId);
    expect(mainStock.quantity, 2000);
    expect(branchStock.quantity, 1000);
  });



  test('rejects duplicate product lines without creating purchase records', () async {
    final productId = await products.add(const Product(
      name: 'منتج مكرر', costMinor: 500, priceMinor: 800,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد التكرار');
    final warehouseId = (await warehouses.warehouses()).single.id;

    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [
          PurchaseLineInput(productId: productId, quantity: 1000, unitCostMinor: 500),
          PurchaseLineInput(productId: productId, quantity: 2000, unitCostMinor: 600),
        ],
        paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await db.query('supplier_account_entries'), isEmpty);
    expect(await db.query('inventory_movements'), isEmpty);
    expect((await products.all()).single.stockQuantity, 0);
  });

  test('rejects inactive supplier, warehouse, and product references', () async {
    final productId = await products.add(const Product(
      name: 'منتج موقوف', costMinor: 500, priceMinor: 800,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد موقوف');
    final warehouseId = (await warehouses.warehouses()).single.id;
    final item = [PurchaseLineInput(
      productId: productId, quantity: 1000, unitCostMinor: 500,
    )];

    await db.update('suppliers', {'is_active': 0},
        where: 'id = ?', whereArgs: [supplierId]);
    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId, warehouseId: warehouseId,
        items: item, paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );
    await db.update('suppliers', {'is_active': 1},
        where: 'id = ?', whereArgs: [supplierId]);

    await db.update('warehouses', {'is_active': 0},
        where: 'id = ?', whereArgs: [warehouseId]);
    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId, warehouseId: warehouseId,
        items: item, paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );
    await db.update('warehouses', {'is_active': 1},
        where: 'id = ?', whereArgs: [warehouseId]);

    await products.setActive(productId: productId, isActive: false);
    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId, warehouseId: warehouseId,
        items: item, paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await db.query('supplier_account_entries'), isEmpty);
    expect(await db.query('inventory_movements'), isEmpty);
    expect((await products.all(includeInactive: true)).single.stockQuantity, 0);
  });

  test('rejects fractional purchase quantity for a whole-unit product', () async {
    final productId = await products.add(const Product(
      name: 'منتج بالقطعة', costMinor: 500, priceMinor: 800,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد القطع');
    final warehouseId = (await warehouses.warehouses()).single.id;

    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [PurchaseLineInput(
          productId: productId, quantity: 500, unitCostMinor: 1000,
        )],
        paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect((await products.all()).single.stockQuantity, 0);
  });

  test('accepts fractional purchase quantity for a fraction-enabled unit', () async {
    final unitId = await products.addUnit(
      name: 'كيلوجرام كسري',
      abbreviation: 'كجم',
      allowsFraction: true,
    );
    final productId = await products.add(Product(
      name: 'منتج بالوزن',
      costMinor: 1500,
      priceMinor: 2500,
      unitId: unitId,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد الوزن');
    final warehouseId = (await warehouses.warehouses()).single.id;

    final purchaseId = await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [PurchaseLineInput(
        productId: productId, quantity: 500, unitCostMinor: 2000,
      )],
      paidMinor: 0,
    );

    final product = (await products.all()).single;
    expect(product.stockQuantity, 500);
    expect(product.costMinor, 2000);
    final purchase = (await db.query('purchases')).single;
    expect(purchase['id'], purchaseId);
    expect(purchase['total_minor'], 1000);
    expect((await db.query('purchase_items')).single['quantity'], 500);
    expect((await db.query('inventory_movements')).single['quantity_delta'], 500);
  });



  test('rejects purchase when the warehouse branch is inactive', () async {
    final productId = await products.add(const Product(
      name: 'منتج فرع موقوف', costMinor: 500, priceMinor: 800,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد فرع موقوف');
    final warehouseId = (await warehouses.warehouses()).single.id;
    final warehouse = (await db.query(
      'warehouses', columns: ['branch_id'],
      where: 'id = ?', whereArgs: [warehouseId],
    )).single;
    await db.update('branches', {'is_active': 0},
        where: 'id = ?', whereArgs: [warehouse['branch_id']]);

    await expectLater(
      purchases.createPurchase(
        supplierId: supplierId,
        warehouseId: warehouseId,
        items: [PurchaseLineInput(
          productId: productId, quantity: 1000, unitCostMinor: 500,
        )],
        paidMinor: 0,
      ),
      throwsA(isA<AppException>()),
    );

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await db.query('supplier_account_entries'), isEmpty);
    expect(await db.query('inventory_movements'), isEmpty);
    expect((await products.all()).single.stockQuantity, 0);
  });

  test('rounds a half-piastre weighted average upward', () async {
    final productId = await products.add(const Product(
      name: 'منتج متوسط نصف قرش', costMinor: 1000, priceMinor: 1500,
      stockQuantity: 1000,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد التقريب');
    final warehouseId = (await warehouses.warehouses()).single.id;

    await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [PurchaseLineInput(
        productId: productId, quantity: 1000, unitCostMinor: 1001,
      )],
      paidMinor: 0,
    );

    expect((await products.all()).single.costMinor, 1001);
    expect((await db.query('purchases')).single['total_minor'], 1001);
  });

}
