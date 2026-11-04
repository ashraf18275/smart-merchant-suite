import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/sales_repository.dart';
import 'package:smart_merchant_suite/application/services/product_application_service.dart';
import 'package:smart_merchant_suite/application/services/sales_application_service.dart';
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
  late ProductApplicationService products;
  late SalesApplicationService sales;
  late ProductRepository productStore;
  late SalesRepository salesStore;
  late WarehouseRepository warehouses;
  late AccountRepository accounts;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    productStore = ProductRepository(database);
    salesStore = SalesRepository(database);
    products = ProductApplicationService(productStore);
    sales = SalesApplicationService(salesStore);
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

  testWidgets('creates a customer return from the sales screen', (tester) async {
    final customerId = await accounts.addCustomer(name: 'عميل اختبار المرتجع');
    await sales.createSale(
      quantities: {(await productStore.all()).single.id!: 1000},
      paidMinor: 1500,
      warehouseId: (await warehouses.warehouses()).single.id,
      customerId: customerId,
    );

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

    await tester.tap(find.text('إنشاء مرتجع عميل'));
    await pumpDatabaseResult(tester);
    expect(find.text('إنشاء مرتجع عميل'), findsNWidgets(2));
    expect(find.textContaining('عميل اختبار المرتجع'), findsOneWidget);

    final quantityField = find.byWidgetPredicate((widget) =>
      widget is TextFormField &&
      widget.decoration?.labelText == 'كمية الإرجاع');
    expect(quantityField, findsOneWidget);
    await tester.enterText(quantityField, '1');
    final reasonField = find.byWidgetPredicate((widget) =>
      widget is TextField && widget.decoration?.labelText == 'سبب المرتجع *');
    await tester.enterText(reasonField, 'تجربة واجهة المرتجع');
    await tester.tap(find.text('حفظ المرتجع'));
    await pumpDatabaseResult(tester);

    expect(await database.query('customer_returns'), hasLength(1));
    expect((await database.query('customer_returns')).single['total_minor'], 1500);
    expect((await database.query('sale_items')).single['returned_quantity'], 1000);
    expect((await productStore.all()).single.stockQuantity, 5000);
    expect((await database.query('customer_account_entries', orderBy: 'id DESC'))
      .first['entry_type'], 'return');
    expect(find.textContaining('تم حفظ مرتجع العميل رقم'), findsOneWidget);
  });

}
