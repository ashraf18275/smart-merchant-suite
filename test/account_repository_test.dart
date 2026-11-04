import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';
import 'package:smart_merchant_suite/data/account_repository.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
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

  test('rejects empty customer names', () async {
    await expectLater(accounts.addCustomer(name: '  '), throwsA(isA<AppException>()));
  });
}
