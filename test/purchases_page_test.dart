import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:smart_merchant_suite/features/purchases_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> pumpDatabaseResult(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late Database database;
  late ProductRepository products;
  late PurchaseRepository purchases;
  late WarehouseRepository warehouses;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    products = ProductRepository(database);
    purchases = PurchaseRepository(database);
    warehouses = WarehouseRepository(database);
  });

  tearDown(() async => database.close());

  testWidgets('loads the purchase form and receives a purchase into stock',
      (tester) async {
    final productId = await products.add(const Product(
      name: 'أرز',
      costMinor: 1000,
      priceMinor: 1500,
    ));

    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: PurchasesPage(
          purchases: purchases,
          products: products,
          warehouses: warehouses,
        ),
      ),
    ));
    await pumpDatabaseResult(tester);

    expect(find.text('المشتريات واستلام المخزون'), findsOneWidget);
    expect(find.text('أصناف الفاتورة'), findsOneWidget);
    expect(find.text('أرز'), findsNothing);

    await tester.tap(find.byTooltip('إضافة مورد'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'مورد الأرز');
    await tester.tap(find.text('حفظ المورد'));
    await tester.pumpAndSettle();
    await pumpDatabaseResult(tester);

    expect(find.text('مورد الأرز'), findsOneWidget);

    await tester.tap(find.text('اختر المنتج'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أرز').last);
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '3');
    await tester.enterText(fields.at(1), '20.00');
    await tester.enterText(fields.at(2), '30.00');
    await pumpDatabaseResult(tester);

    expect(find.text('إجمالي البند: 60.00 ج.م'), findsOneWidget);
    expect(find.text('60.00 ج.م'), findsOneWidget);

    await tester.ensureVisible(find.text('حفظ الفاتورة واستلام المخزون'));
    await tester.tap(find.text('حفظ الفاتورة واستلام المخزون'));
    await tester.pumpAndSettle();
    await pumpDatabaseResult(tester);

    expect(find.textContaining('تم استلام المشتريات وحفظ الفاتورة رقم'),
        findsOneWidget);
    expect((await products.all()).single.stockQuantity, 3000);
    expect((await database.query('purchases')).single['total_minor'], 6000);
    expect((await database.query('purchases')).single['paid_minor'], 3000);
    final entries = await database.query(
      'supplier_account_entries',
      orderBy: 'id ASC',
    );
    expect(entries.map((row) => row['amount_minor']), [6000, -3000]);
    expect((await database.query('purchase_items')).single['product_id'],
        productId);
    expect((await database.query('inventory_movements')).length, 1);
  });

  testWidgets('requires a supplier and product before saving',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: PurchasesPage(
          purchases: purchases,
          products: products,
          warehouses: warehouses,
        ),
      ),
    ));
    await pumpDatabaseResult(tester);

    await tester.tap(find.text('حفظ الفاتورة واستلام المخزون'));
    await tester.pump();
    expect(find.text('أضف موردًا واختر مخزنًا نشطًا أولًا.'), findsOneWidget);
    expect(await database.query('purchases'), isEmpty);
  });
}
