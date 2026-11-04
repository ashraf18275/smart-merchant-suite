import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/audit_cash_writer.dart';
import 'package:smart_merchant_suite/data/cashbook_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/features/cashbook_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late CashbookRepository repository;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    repository = CashbookRepository(db);
  });
  tearDown(() async => db.close());

  testWidgets('opens a shift and shows its opening and expected balance', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CashbookPage(repository: repository),
    ));
    await tester.pumpAndSettle();

    expect(find.text('لا توجد وردية صندوق مفتوحة.'), findsOneWidget);
    await tester.tap(find.text('فتح وردية وتسجيل الرصيد الافتتاحي'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '50.00');
    await tester.tap(find.text('فتح الوردية'));
    await tester.pumpAndSettle();

    expect(find.text('وردية مفتوحة'), findsOneWidget);
    expect(find.text('الرصيد الافتتاحي: 50.00 ج.م'), findsOneWidget);
    expect(find.text('الرصيد المتوقع حاليًا: 50.00 ج.م'), findsOneWidget);
  });

  testWidgets('closes a shift using the counted cash and shows the difference', (tester) async {
    final sessionId = await repository.openSession(openingBalanceMinor: 10000);
    await db.transaction((txn) => writeCashMovement(
      txn,
      direction: 'in',
      category: 'sale_receipt',
      amountMinor: 2500,
      sourceType: 'sale',
      sourceId: 77,
    ));

    await tester.pumpWidget(MaterialApp(
      home: CashbookPage(repository: repository),
    ));
    await tester.pumpAndSettle();

    expect(find.text('الرصيد المتوقع حاليًا: 125.00 ج.م'), findsOneWidget);
    await tester.tap(find.text('عد النقدية وإقفال الوردية'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '120.00');
    await tester.tap(find.text('تأكيد الإقفال'));
    await tester.pumpAndSettle();

    final history = await repository.sessionHistory();
    expect(history, hasLength(1));
    expect(history.single['id'], sessionId);
    expect(history.single['expected_balance_minor'], 12500);
    expect(history.single['counted_balance_minor'], 12000);
    expect(history.single['difference_minor'], -500);
    expect(find.textContaining('عجز'), findsWidgets);
  });
}
