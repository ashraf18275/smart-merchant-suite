import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/features/products_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late ProductRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
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
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'USB');
    await tester.pumpAndSettle();

    expect(find.text('كابل USB'), findsOneWidget);
    expect(find.text('شاحن سريع'), findsNothing);
  });
}
