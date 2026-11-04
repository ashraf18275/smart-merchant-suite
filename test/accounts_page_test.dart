import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:smart_merchant_suite/features/accounts_page.dart';

Future<void> pumpDatabaseResult(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late Database database;
  late AccountRepository accounts;
  late PurchaseRepository purchases;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
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
    await pumpDatabaseResult(tester);

    expect(find.text('حسابات العملاء والموردين'), findsOneWidget);
    expect(find.text('مورد الواجهة'), findsOneWidget);
    expect(find.text('123.45 ج.م'), findsNWidgets(2));
    expect(find.text('فاتورة مشتريات'), findsOneWidget);

    await tester.tap(find.text('العملاء'));
    await pumpDatabaseResult(tester);
    expect(find.text('لا توجد حسابات مسجلة في هذا القسم.'), findsOneWidget);
  });

  testWidgets('creates a customer with a signed opening balance from the accounts screen', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AccountsPage(accounts: accounts, purchases: purchases),
    ));
    await pumpDatabaseResult(tester);

    await tester.tap(find.text('العملاء'));
    await pumpDatabaseResult(tester);
    await tester.tap(find.text('إضافة عميل جديد'));
    await pumpDatabaseResult(tester);

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), 'عميل افتتاحي');
    await tester.enterText(fields.at(1), '75.00');
    await tester.tap(find.text('حفظ الحساب'));
    await pumpDatabaseResult(tester);

    final customer = (await accounts.customers()).single;
    expect(customer['name'], 'عميل افتتاحي');
    expect(await accounts.customerBalance(customer['id']! as int), 7500);
    expect(await database.query('cash_transactions'), isEmpty);
  });

  testWidgets('explains supplier credit balance and does not offer a supplier payment', (tester) async {
    await purchases.addSupplier(
      name: 'مورد له رصيد',
      openingBalanceMinor: -4500,
    );
    await tester.pumpWidget(MaterialApp(
      home: AccountsPage(accounts: accounts, purchases: purchases),
    ));
    await pumpDatabaseResult(tester);

    expect(find.text('رصيد لنا لدى المورد'), findsOneWidget);
    expect(find.text('-45.00 ج.م'), findsNWidgets(2));
    final paymentButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'تسجيل سداد للمورد'),
    );
    expect(paymentButton.onPressed, isNull);
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
    await pumpDatabaseResult(tester);

    await tester.tap(find.text('تسجيل سداد للمورد'));
    await pumpDatabaseResult(tester);
    await tester.enterText(find.byType(TextFormField).last, '25.00');
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await pumpDatabaseResult(tester);

    expect(await accounts.supplierBalance(supplierId), 7500);
    expect(find.text('تم تسجيل سداد المورد'), findsOneWidget);
  });
}
