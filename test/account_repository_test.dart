import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:smart_merchant_suite/domain/payment_method.dart';
import 'package:smart_merchant_suite/data/purchase_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AccountRepository accounts;
  late PurchaseRepository purchases;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLocalSchema(db);
    accounts = AccountRepository(db);
    purchases = PurchaseRepository(db);
  });
  tearDown(() async => db.close());

  test('creates customer opening balances as signed ledger entries without cash movement', () async {
    final debitCustomer = await accounts.addCustomer(
      name: 'عميل رصيد مدين',
      openingBalanceMinor: 12500,
    );
    final creditCustomer = await accounts.addCustomer(
      name: 'عميل رصيد دائن',
      openingBalanceMinor: -3500,
    );
    expect(await accounts.customerBalance(debitCustomer), 12500);
    expect(await accounts.customerBalance(creditCustomer), -3500);
    final entries = await db.query('customer_account_entries',
      orderBy: 'id ASC');
    expect(entries.map((row) => row['amount_minor']), [12500, -3500]);
    expect(entries.every((row) => row['entry_type'] == 'adjustment'), isTrue);
    expect(entries.every((row) => row['note'] == 'رصيد افتتاحي عند إنشاء الحساب'), isTrue);
    expect(await db.query('cash_transactions'), isEmpty);
    expect(await db.query('payment_records'), isEmpty);
    final events = await db.query('audit_events',
      where: "action = 'customer_created'");
    expect(events, hasLength(2));
  });

  test('lists only active customers alphabetically for sales selection', () async {
    final zed = await accounts.addCustomer(name: 'زيد');
    final ahmed = await accounts.addCustomer(name: 'أحمد');
    final inactive = await accounts.addCustomer(name: 'عميل موقوف');
    await db.update('customers', {'is_active': 0}, where: 'id = ?', whereArgs: [inactive]);

    final customers = await accounts.customers();
    expect(customers.map((row) => row['id']), [ahmed, zed]);
    expect(customers.map((row) => row['name']), ['أحمد', 'زيد']);
  });

  test('records supplier payments and returns a chronological running balance', () async {
    final supplierId = await purchases.addSupplier(name: 'مورد');
    await db.insert('supplier_account_entries', {
      'supplier_id': supplierId,
      'amount_minor': 10000,
      'entry_type': 'purchase',
      'created_at': '2026-01-01T10:00:00.000Z',
    });
    await accounts.recordSupplierPayment(supplierId: supplierId, amountMinor: 2500);
    expect(await accounts.supplierBalance(supplierId), 7500);
    final statement = await accounts.supplierStatement(supplierId);
    expect(statement.map((row) => row['running_balance_minor']), [10000, 7500]);
    expect(statement.last['amount_minor'], -2500);
    final cash = (await db.query('cash_transactions')).single;
    expect(cash['direction'], 'out');
    expect(cash['category'], 'supplier_payment');
    expect(cash['amount_minor'], 2500);
    expect((await db.query('audit_events')).single['action'], 'supplier_payment_recorded');
  });

  test('records customer receipts and rejects overpayment and non-positive values', () async {
    final customerId = await accounts.addCustomer(name: 'عميل');
    await db.insert('customer_account_entries', {
      'customer_id': customerId,
      'amount_minor': 4000,
      'entry_type': 'sale',
      'created_at': '2026-01-01T10:00:00.000Z',
    });
    await accounts.recordCustomerReceipt(customerId: customerId, amountMinor: 1500);
    expect(await accounts.customerBalance(customerId), 2500);
    final cash = (await db.query('cash_transactions')).single;
    expect(cash['direction'], 'in');
    expect(cash['category'], 'customer_receipt');
    expect(cash['amount_minor'], 1500);
    expect((await db.query('audit_events')).single['action'], 'customer_receipt_recorded');
    await expectLater(
      accounts.recordCustomerReceipt(customerId: customerId, amountMinor: 2501),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      accounts.recordCustomerReceipt(customerId: customerId, amountMinor: 0),
      throwsA(isA<AppException>()),
    );
    expect(await accounts.customerBalance(customerId), 2500);
  });

  test('records electronic customer receipt without cash movement', () async {
    final customerId = await accounts.addCustomer(name: 'عميل بطاقة');
    await db.insert('customer_account_entries', {
      'customer_id': customerId,
      'amount_minor': 6000,
      'entry_type': 'sale',
      'created_at': '2026-01-01T10:00:00.000Z',
    });
    final entryId = await accounts.recordCustomerReceipt(
      customerId: customerId,
      amountMinor: 2000,
      paymentMethod: PaymentMethod.card,
    );
    final payment = (await db.query('payment_records')).single;
    expect(payment['source_type'], 'customer_receipt');
    expect(payment['source_id'], entryId);
    expect(payment['payment_method'], 'card');
    expect(payment['direction'], 'in');
    expect(await db.query('cash_transactions'), isEmpty);
    expect(await accounts.customerBalance(customerId), 4000);
  });

  test('rejects empty customer names', () async {
    await expectLater(accounts.addCustomer(name: '  '), throwsA(isA<AppException>()));
  });
}
