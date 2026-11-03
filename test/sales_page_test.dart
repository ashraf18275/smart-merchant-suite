import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:smart_merchant_suite/features/sales_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> pumpDatabaseResult(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late Database database;
  late ProductRepository products;
  late SalesRepository sales;
  late WarehouseRepository warehouses;
  late AccountRepository accounts;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    products = ProductRepository(database);
    sales = SalesRepository(database);
    warehouses = WarehouseRepository(database);
    accounts = AccountRepository(database);
    await products.add(const Product(
      name: 'منتج اختبار',
      costMinor: 700,
      priceMinor: 1500,
      stockQuantity: 5000,
    ));
  });

  tearDown(() async => database.close());

  testWidgets('sale quantity and payment fields start empty and accept blank as zero',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: SalesPage(
          products: products,
          sales: sales,
          warehouseStore: warehouses,
          accountRepository: accounts,
        ),
      ),
    ));
    await pumpDatabaseResult(tester);

    await tester.tap(find.text('فاتورة جديدة'));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields, hasLength(2));
    expect(fields.every((field) => field.controller?.text.isEmpty ?? false), isTrue);

    await tester.tap(find.text('حفظ الفاتورة'));
    await tester.pump();
    expect(find.text('أدخل كمية لصنف واحد على الأقل'), findsOneWidget);
    expect(await database.query('sales'), isEmpty);
  });
}
