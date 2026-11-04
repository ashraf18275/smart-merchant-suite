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

    await tester.scrollUntilVisible(
      find.text('حفظ الفاتورة واستلام المخزون'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
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

  testWidgets('requires a supplier before saving a purchase',
      (tester) async {
    await products.add(const Product(
      name: 'منتج اختبار',
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

    await tester.scrollUntilVisible(
      find.text('حفظ الفاتورة واستلام المخزون'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الفاتورة واستلام المخزون'));
    await tester.pump();
    expect(find.text('أضف موردًا واختر مخزنًا نشطًا أولًا.'), findsOneWidget);
    expect(await database.query('purchases'), isEmpty);
  });
  testWidgets('creates a supplier return from the purchases screen', (tester) async {
    final productId = await products.add(const Product(
      name: 'صنف مرتجع من الواجهة',
      costMinor: 1000,
      priceMinor: 1500,
    ));
    final supplierId = await purchases.addSupplier(name: 'مورد اختبار الواجهة');
    final warehouseId = (await warehouses.warehouses()).single.id;
    await purchases.createPurchase(
      supplierId: supplierId,
      warehouseId: warehouseId,
      items: [PurchaseLineInput(
        productId: productId,
        quantity: 3000,
        unitCostMinor: 2000,
      )],
      paidMinor: 0,
    );

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

    await tester.tap(find.text('إنشاء مرتجع مورد'));
    await pumpDatabaseResult(tester);
    expect(find.text('إنشاء مرتجع مورد'), findsOneWidget);
    expect(find.textContaining('مورد اختبار الواجهة'), findsOneWidget);
    expect(find.text('صنف مرتجع من الواجهة'), findsOneWidget);

    final quantityField = find.byWidgetPredicate((widget) =>
      widget is TextField &&
      widget.decoration?.labelText?.startsWith('الكمية المرتجعة') == true);
    expect(quantityField, findsOneWidget);
    await tester.enterText(quantityField, '1');
    final reasonField = find.byWidgetPredicate((widget) =>
      widget is TextField && widget.decoration?.labelText == 'سبب المرتجع *');
    await tester.enterText(reasonField, 'بضاعة تالفة');
    await tester.tap(find.text('حفظ المرتجع'));
    await pumpDatabaseResult(tester);

    expect(await database.query('supplier_returns'), hasLength(1));
    expect((await database.query('supplier_returns')).single['total_minor'], 2000);
    expect((await products.all()).single.stockQuantity, 2000);
    expect((await database.query('purchase_items')).single['returned_quantity'], 1000);
    expect((await database.query('supplier_account_entries', orderBy: 'id DESC'))
        .first['entry_type'], 'return');
    expect(find.textContaining('تم حفظ مرتجع المورد رقم'), findsOneWidget);
  });

}
