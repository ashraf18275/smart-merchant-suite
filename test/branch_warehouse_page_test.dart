import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/warehouse_repository.dart';
import 'package:smart_merchant_suite/features/branch_warehouse_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settleCatalog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late Database database;
  late WarehouseRepository store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    store = WarehouseRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('adds a branch from the branch management tab', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: BranchWarehousePage(store: store),
      ),
    ));
    await settleCatalog(tester);

    await tester.tap(find.text('إضافة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'فرع الاختبار');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    await settleCatalog(tester);

    expect(find.text('فرع الاختبار'), findsOneWidget);
  });

  testWidgets('adds a warehouse under the selected branch', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: BranchWarehousePage(store: store),
      ),
    ));
    await settleCatalog(tester);

    await tester.tap(find.text('المخازن'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'مخزن الأدوات');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    await settleCatalog(tester);

    expect(find.text('مخزن الأدوات'), findsOneWidget);
  });
}
