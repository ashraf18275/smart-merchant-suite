import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/features/products_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> pumpDatabaseResult(WidgetTester tester) async {
  // Use the no-isolate SQLite FFI backend below so database futures can
  // complete deterministically inside Flutter's widget-test fake async zone.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  late Database database;
  late ProductRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    repository = ProductRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('shows an empty state when there are no products',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ProductsPage(repository: repository),
      ),
    ));
    await pumpDatabaseResult(tester);

    expect(find.text('المنتجات والمخزون'), findsOneWidget);
    expect(find.text('لا توجد منتجات بعد. اضغط «إضافة منتج» للبدء.'), findsOneWidget);
  });

  testWidgets('adds a product and shows it in the list', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ProductsPage(repository: repository),
      ),
    ));
    await pumpDatabaseResult(tester);

    await tester.tap(find.text('إضافة منتج'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(5));
    await tester.enterText(fields.at(0), 'كابل USB');
    await tester.enterText(fields.at(1), 'USB-01');
    await tester.enterText(fields.at(2), '12.50');
    await tester.enterText(fields.at(3), '20.00');
    await tester.enterText(fields.at(4), '3');
    await tester.tap(find.text('حفظ المنتج'));
    await tester.pumpAndSettle();
    await pumpDatabaseResult(tester);

    expect(find.text('كابل USB'), findsOneWidget);
    expect(find.textContaining('12.50 ج.م'), findsOneWidget);
    expect(find.textContaining('20.00 ج.م'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('filters products by search text', (tester) async {
    await repository.add(const Product(
      name: 'كابل USB',
      sku: 'USB-01',
      costMinor: 1250,
      priceMinor: 2000,
    ));
    await repository.add(const Product(
      name: 'شاحن سريع',
      sku: 'CHG-02',
      costMinor: 5000,
      priceMinor: 7500,
    ));

    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ProductsPage(repository: repository),
      ),
    ));
    await pumpDatabaseResult(tester);

    await tester.enterText(find.byType(TextField), 'USB');
    await pumpDatabaseResult(tester);

    expect(find.text('كابل USB'), findsOneWidget);
    expect(find.text('شاحن سريع'), findsNothing);
  });
  testWidgets('records stock adjustments and refreshes the quantity',
      (tester) async {
    await repository.add(const Product(
      name: 'شاحن',
      costMinor: 500,
      priceMinor: 900,
      stockQuantity: 3,
    ));

    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ProductsPage(repository: repository),
      ),
    ));
    await pumpDatabaseResult(tester);

    await tester.tap(find.byTooltip('تعديل المخزون'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '-1');
    await tester.enterText(fields.at(1), 'تصحيح جرد');
    await tester.tap(find.text('تسجيل الحركة'));
    await tester.pumpAndSettle();
    await pumpDatabaseResult(tester);

    expect(find.text('2'), findsOneWidget);
    final movements = await database.query('inventory_movements');
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], -1);
    expect(movements.single['reason'], 'تصحيح جرد');
  });

}
