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

  testWidgets('creates a unit and can hide and restore an unused unit', (tester) async {
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
    await tester.enterText(fields.at(0), 'وحدة تجريبية');
    await tester.enterText(fields.at(1), 'وحدة تجريبية');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);

    final createdUnits = await catalog.units(includeInactive: true);
    final createdUnit = createdUnits.singleWhere((unit) => unit.name == 'وحدة تجريبية');
    expect(createdUnit.abbreviation, 'وحدة تجريبية');
    expect(createdUnit.allowsFraction, isFalse);
    expect(createdUnit.isActive, isTrue);

    // The database write and the widget rebuild are separate asynchronous
    // operations. Wait for the catalog reload to be rendered before asserting
    // that the newly-created unit is visible.
    // sqflite_ffi completes through the real async event loop. Widget-test
    // frame settling alone does not wait for the repository reload started by
    // the dialog callback, so allow that future to complete before rendering.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('وحدة تجريبية'), findsOneWidget);
    final unitCard = find.ancestor(of: find.text('وحدة تجريبية'), matching: find.byType(Card));
    await tester.tap(find.descendant(of: unitCard, matching: find.byTooltip('إخفاء الوحدة')));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);
    final deactivatedUnits = await catalog.units(includeInactive: true);
    final deactivatedUnit = deactivatedUnits.singleWhere((unit) => unit.name == 'وحدة تجريبية');
    expect(deactivatedUnit.isActive, isFalse);
    expect(find.text('وحدة تجريبية'), findsOneWidget);
    await tester.tap(find.byTooltip('إظهار الوحدة'));
    await tester.pumpAndSettle();
    await pumpCatalog(tester);
    final restoredUnits = await catalog.units(includeInactive: true);
    final restoredUnit = restoredUnits.singleWhere((unit) => unit.name == 'وحدة تجريبية');
    expect(restoredUnit.isActive, isTrue);
  });
}
