import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/application/services/product_application_service.dart';
import 'package:smart_merchant_suite/application/services/sales_application_service.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/domain/product.dart';
import 'package:smart_merchant_suite/features/sales_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settleDatabase(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late Database database;
  late ProductRepository products;
  late WarehouseRepository warehouses;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    products = ProductRepository(database);
    warehouses = WarehouseRepository(database);
    await products.add(const Product(
      name: 'منتج اختبار',
      sku: 'SALE-01',
      costMinor: 100,
      priceMinor: 250,
      stockQuantity: 3000,
    ));
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('saves a sale with blank paid amount as zero', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: SalesPage(
          products: ProductApplicationService(products),
          sales: SalesApplicationService(SalesRepository(database)),
          warehouseStore: warehouses,
        ),
      ),
    ));
    await settleDatabase(tester);

    await tester.tap(find.text('فاتورة جديدة'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '1');
    // The payment field intentionally remains empty.
    await tester.tap(find.text('حفظ الفاتورة'));
    await tester.pumpAndSettle();
    await settleDatabase(tester);

    final sales = await database.query('sales');
    expect(sales, hasLength(1));
    expect(sales.single['total_minor'], 250);
    expect(sales.single['paid_minor'], 0);
    expect(find.textContaining('تم حفظ الفاتورة رقم'), findsOneWidget);
  });
}
