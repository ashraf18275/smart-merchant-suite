import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late ProductRepository products;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    products = ProductRepository(database);
  });

  tearDown(() async {
    await database.close();
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
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 4);
  });

  test('rejects stock below zero without writing a movement', () async {
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
      throwsA(isA<StateError>()),
    );

    expect((await products.all()).single.stockQuantity, 1);
    expect(await database.query('inventory_movements'), isEmpty);
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
    expect(await database.query('inventory_movements'), hasLength(1));
    await expectLater(
      products.changeStock(
        productId: id,
        quantityDelta: 1,
        reason: 'محاولة بعد الإيقاف',
      ),
      throwsA(isA<StateError>()),
    );

    await products.setActive(productId: id, isActive: true);
    expect((await products.all()).single.isActive, isTrue);
  });

  test('rejects empty product names', () async {
    await expectLater(
      products.add(const Product(
        name: '   ',
        costMinor: 0,
        priceMinor: 100,
      )),
      throwsArgumentError,
    );
  });
}
