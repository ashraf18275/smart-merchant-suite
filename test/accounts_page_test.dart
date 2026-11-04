import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:smart_merchant_suite/features/accounts_page.dart';

void main() {
  late Database database;
  late AccountRepository accounts;
  late PurchaseRepository purchases;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(database);
    accounts = AccountRepository(database);
    purchases = PurchaseRepository(database);
  });

  tearDown(() async => database.close());

  testWidgets('shows supplier balance and switches to customer accounts', (tester) async {
    final supplierId = await purchases.addSupplier(name: 'مورد الواجهة');
    await database.insert('supplier_account_entries', {
      'supplier_id': supplierId,
      'amount_minor': 12345,
      'entry_type': 'purchase',
      'note': 'فاتورة اختبار',
      'created_at': '2026-11-01T10:00:00.000Z',
    });

    await tester.pumpWidget(MaterialApp(
      home: AccountsPage(accounts: accounts, purchases: purchases),
    ));
    await tester.pumpAndSettle();

    expect(find.text('حسابات العملاء والموردين'), findsOneWidget);
    expect(find.text('مورد الواجهة'), findsOneWidget);
    expect(find.text('123.45 ج.م'), findsNWidgets(2));
    expect(find.text('فاتورة مشتريات'), findsOneWidget);

    await tester.tap(find.text('العملاء'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد حسابات مسجلة في هذا القسم.'), findsOneWidget);
  });

  testWidgets('records a supplier payment from the account statement', (tester) async {
    final supplierId = await purchases.addSupplier(name: 'مورد السداد');
    await database.insert('supplier_account_entries', {
      'supplier_id': supplierId,
      'amount_minor': 10000,
      'entry_type': 'purchase',
      'created_at': '2026-11-01T10:00:00.000Z',
    });

    await tester.pumpWidget(MaterialApp(
      home: AccountsPage(accounts: accounts, purchases: purchases),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('تسجيل سداد للمورد'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'المبلغ بالجنيه *'), '25.00');
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();

    expect(await accounts.supplierBalance(supplierId), 7500);
    expect(find.text('تم تسجيل سداد المورد'), findsOneWidget);
  });
}
