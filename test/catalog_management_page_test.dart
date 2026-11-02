import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/product_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/features/catalog_management_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> pumpCatalog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  late Database database;
  late ProductRepository catalog;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    catalog = ProductRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('creates and edits a product category', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: CatalogManagementPage(catalog: catalog),
      ),
    ));
    await pumpCatalog(tester);

    await tester.tap(find.text('إضافة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'مشروبات');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);

    expect(find.text('مشروبات'), findsOneWidget);

    await tester.tap(find.byTooltip('تعديل التصنيف'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'مشروبات باردة');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);

    expect(find.text('مشروبات باردة'), findsOneWidget);
    expect(find.text('مشروبات'), findsNothing);
  });

  testWidgets('creates a unit and can deactivate it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: CatalogManagementPage(catalog: catalog),
      ),
    ));
    await pumpCatalog(tester);

    await tester.tap(find.text('وحدات القياس'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'طن');
    await tester.enterText(fields.at(1), 'طن');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);

    expect(find.text('طن • أعداد صحيحة فقط • نشطة'), findsOneWidget);
    final unitCard = find.ancestor(of: find.text('طن'), matching: find.byType(Card));
    await tester.tap(find.descendant(of: unitCard, matching: find.byTooltip('إيقاف الوحدة')));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);
    expect(find.text('طن • أعداد صحيحة فقط • موقوفة'), findsOneWidget);
  });
}
