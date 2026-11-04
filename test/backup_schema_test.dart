import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/backup_schema.dart';

void main() {
  test('accepts supported historical and current backup versions only', () {
    for (var version = 3; version <= BackupSchema.currentVersion; version++) {
      expect(BackupSchema.supports(version), isTrue, reason: 'version $version');
    }
    expect(BackupSchema.supports(2), isFalse);
    expect(BackupSchema.supports(12), isFalse);
  });

  test('maps purchase and account data to the schema versions that introduced them', () {
    expect(BackupSchema.hasPurchaseData(7), isFalse);
    expect(BackupSchema.hasPurchaseData(8), isTrue);
    expect(BackupSchema.hasPurchaseData(9), isTrue);
    expect(BackupSchema.hasAccountData(8), isFalse);
    expect(BackupSchema.hasAccountData(9), isTrue);
    expect(BackupSchema.hasSupplierReturnData(9), isFalse);
    expect(BackupSchema.hasSupplierReturnData(10), isTrue);
    expect(BackupSchema.hasCustomerReturnData(10), isFalse);
    expect(BackupSchema.hasCustomerReturnData(11), isTrue);
  });

  test('restore ordering covers every current business table', () {
    expect(
      BackupSchema.restoreDeleteOrder.toSet(),
      BackupSchema.currentTableNames,
    );
    expect(
      BackupSchema.restoreInsertOrder.toSet(),
      BackupSchema.currentTableNames,
    );

    // Explicitly protect important parent-child relationships.
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('purchase_items'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('purchases')),
    );
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('purchases'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('suppliers')),
    );
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('sales'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('customers')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('suppliers'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('purchases')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('customers'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('sales')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('purchases'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('purchase_items')),
    );
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('supplier_return_items'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('supplier_returns')),
    );
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('supplier_returns'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('purchase_items')),
    );
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('customer_return_items'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('customer_returns')),
    );
    expect(
      BackupSchema.restoreDeleteOrder.indexOf('customer_returns'),
      lessThan(BackupSchema.restoreDeleteOrder.indexOf('sale_items')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('sale_items'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('customer_return_items')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('sales'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('customer_returns')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('purchase_items'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('supplier_return_items')),
    );
    expect(
      BackupSchema.restoreInsertOrder.indexOf('purchases'),
      lessThan(BackupSchema.restoreInsertOrder.indexOf('supplier_returns')),
    );
  });
}
