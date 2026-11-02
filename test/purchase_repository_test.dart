import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
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
      items: [PurchaseLineInput(productId: productId, quantity: 1500, unitCostMinor: 1250)],
      paidMinor: 0,
    );
    final product = (await products.all()).single;
    expect(product.stockQuantity, 1500);
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
}
