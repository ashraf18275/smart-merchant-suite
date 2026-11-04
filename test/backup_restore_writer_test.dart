import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/backup_restore_writer.dart';
import 'package:smart_merchant_suite/data/backup_schema.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('PRAGMA foreign_keys = ON');
    await createLocalSchema(database);
  });

  tearDown(() async => database.close());

  Future<Map<String, List<Map<String, Object?>>>> captureBusinessData(
    DatabaseExecutor executor,
  ) async {
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in BackupSchema.restoreInsertOrder) {
      result[table] = await executor.query(table, orderBy: 'id ASC');
    }
    return result;
  }

  Future<Map<String, Object?>> seedCompleteBusinessData() async {
    final stamp = DateTime.utc(2026, 11, 3).toIso8601String();
    final branch = (await database.query('branches')).single;
    final warehouse = (await database.query('warehouses')).single;
    final unit = (await database.query('product_units')).single;

    final supplierId = await database.insert('suppliers', {
      'name': 'مورد الاختبار',
      'phone': '01000000000',
      'address': 'القاهرة',
      'is_active': 1,
      'created_at': stamp,
    });
    final customerId = await database.insert('customers', {
      'name': 'عميل الاختبار',
      'phone': '01100000000',
      'address': 'الجيزة',
      'is_active': 1,
      'created_at': stamp,
    });
    final productId = await database.insert('products', {
      'name': 'منتج النسخ الاحتياطي',
      'sku': 'BACKUP-001',
      'cost_minor': 125,
      'price_minor': 250,
      'stock_quantity': 3000,
      'unit_id': unit['id'],
      'is_active': 1,
      'created_at': stamp,
    });
    await database.insert('product_warehouse_stock', {
      'product_id': productId,
      'warehouse_id': warehouse['id'],
      'quantity': 3000,
      'updated_at': stamp,
    });
    final saleId = await database.insert('sales', {
      'total_minor': 500,
      'paid_minor': 200,
      'warehouse_id': warehouse['id'],
      'customer_id': customerId,
      'created_at': stamp,
    });
    await database.insert('sale_items', {
      'sale_id': saleId,
      'product_id': productId,
      'quantity': 2000,
      'returned_quantity': 500,
      'returned_minor': 125,
      'returned_cost_minor': 63,
      'unit_price_minor': 250,
      'unit_cost_minor': 125,
      'line_total_minor': 500,
    });

    final customerReturnId = await database.insert('customer_returns', {
      'sale_id': saleId,
      'customer_id': customerId,
      'warehouse_id': warehouse['id'],
      'total_minor': 125,
      'refunded_minor': 50,
      'reason': 'جزء مرتجع',
      'created_at': stamp,
    });
    await database.insert('customer_return_items', {
      'customer_return_id': customerReturnId,
      'sale_item_id': (await database.query('sale_items')).single['id'],
      'product_id': productId,
      'quantity': 500,
      'unit_price_minor': 250,
      'unit_cost_minor': 125,
      'line_total_minor': 125,
      'line_cost_minor': 63,
    });
    await database.insert('expenses', {
      'description': 'مصروف اختبار',
      'category': 'تشغيل',
      'amount_minor': 75,
      'created_at': stamp,
    });
    await database.insert('inventory_movements', {
      'product_id': productId,
      'warehouse_id': warehouse['id'],
      'quantity_delta': 3000,
      'reason': 'رصيد افتتاحي',
      'created_at': stamp,
    });
    final purchaseId = await database.insert('purchases', {
      'supplier_id': supplierId,
      'warehouse_id': warehouse['id'],
      'total_minor': 250,
      'paid_minor': 100,
      'created_at': stamp,
    });
    await database.insert('purchase_items', {
      'purchase_id': purchaseId,
      'product_id': productId,
      'quantity': 2000,
      'returned_quantity': 500,
      'unit_cost_minor': 125,
      'line_total_minor': 250,
    });
    final supplierReturnId = await database.insert('supplier_returns', {
      'purchase_id': purchaseId,
      'supplier_id': supplierId,
      'warehouse_id': warehouse['id'],
      'total_minor': 63,
      'reason': 'جزء تالف',
      'created_at': stamp,
    });
    await database.insert('supplier_return_items', {
      'supplier_return_id': supplierReturnId,
      'purchase_item_id': (await database.query('purchase_items')).single['id'],
      'product_id': productId,
      'quantity': 500,
      'unit_cost_minor': 125,
      'line_total_minor': 63,
    });
    await database.insert('supplier_account_entries', {
      'supplier_id': supplierId,
      'amount_minor': 150,
      'entry_type': 'purchase',
      'reference_id': purchaseId,
      'note': 'رصيد مستحق',
      'created_at': stamp,
    });

    await database.insert('customer_account_entries', {
      'customer_id': customerId,
      'amount_minor': -125,
      'entry_type': 'return',
      'reference_id': customerReturnId,
      'note': 'قيمة المرتجع',
      'created_at': stamp,
    });
    await database.insert('customer_account_entries', {
      'customer_id': customerId,
      'amount_minor': 50,
      'entry_type': 'refund',
      'reference_id': customerReturnId,
      'note': 'استرداد نقدي',
      'created_at': stamp,
    });
    await database.insert('customer_account_entries', {
      'customer_id': customerId,
      'amount_minor': 300,
      'entry_type': 'sale',
      'reference_id': saleId,
      'note': 'رصيد العميل',
      'created_at': stamp,
    });
    return {
      'branch_id': branch['id']!,
      'warehouse_id': warehouse['id']!,
      'supplier_id': supplierId,
      'customer_id': customerId,
      'product_id': productId,
      'purchase_id': purchaseId,
      'sale_id': saleId,
    };
  }

  test('round-trips all current business tables and their relationships', () async {
    final ids = await seedCompleteBusinessData();
    final backup = await captureBusinessData(database);

    await database.update(
      'products',
      {'price_minor': 999},
      where: 'id = ?',
      whereArgs: [ids['product_id']],
    );
    await database.delete('supplier_account_entries');

    await database.transaction(
      (txn) => replaceBackupBusinessData(txn, backup),
    );

    for (final table in BackupSchema.restoreInsertOrder) {
      expect(
        await database.query(table, orderBy: 'id ASC'),
        equals(backup[table]),
        reason: 'table $table must be restored exactly',
      );
    }
    expect(
      await database.rawQuery('PRAGMA foreign_key_check'),
      isEmpty,
    );
    expect(
      (await database.query(
        'sales',
        where: 'id = ?',
        whereArgs: [ids['sale_id']],
      )).single['customer_id'],
      ids['customer_id'],
    );
    expect(
      (await database.query(
        'purchases',
        where: 'id = ?',
        whereArgs: [ids['purchase_id']],
      )).single['supplier_id'],
      ids['supplier_id'],
    );
  });

  test('rolls back the entire replacement when a late foreign key insert fails', () async {
    await seedCompleteBusinessData();
    final before = await captureBusinessData(database);
    final invalid = {
      for (final entry in before.entries)
        entry.key: List<Map<String, Object?>>.from(entry.value),
    };
    invalid['supplier_account_entries']!.add({
      'id': 999,
      'supplier_id': 999999,
      'amount_minor': 10,
      'entry_type': 'adjustment',
      'reference_id': null,
      'note': 'invalid supplier',
      'created_at': DateTime.utc(2026, 11, 3).toIso8601String(),
    });

    await expectLater(
      database.transaction(
        (txn) => replaceBackupBusinessData(txn, invalid),
      ),
      throwsA(anything),
    );

    for (final table in BackupSchema.restoreInsertOrder) {
      expect(
        await database.query(table, orderBy: 'id ASC'),
        equals(before[table]),
        reason: 'failed restore must preserve existing table $table',
      );
    }
    expect(await database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('rejects an incomplete backup payload before deleting existing data', () async {
    await seedCompleteBusinessData();
    final before = await captureBusinessData(database);
    final incomplete = Map<String, List<Map<String, Object?>>>.from(before)
      ..remove('customer_account_entries');

    await expectLater(
      replaceBackupBusinessData(database, incomplete),
      throwsA(isA<StateError>()),
    );

    for (final table in BackupSchema.restoreInsertOrder) {
      expect(
        await database.query(table, orderBy: 'id ASC'),
        equals(before[table]),
        reason: 'incomplete payload must not change $table',
      );
    }
  });


  test('restores normalized version 8 and version 7 payloads without inventing history', () async {
    final ids = await seedCompleteBusinessData();
    final current = await captureBusinessData(database);

    final version8 = {
      for (final entry in current.entries)
        entry.key: entry.value.map((row) => Map<String, Object?>.from(row)).toList(),
    };
    version8['customers'] = [];
    version8['supplier_account_entries'] = [];
    version8['customer_account_entries'] = [];
    version8['sale_items'] = version8['sale_items']!.map((row) => {
      ...row, 'returned_quantity': 0, 'returned_minor': 0, 'returned_cost_minor': 0,
    }).toList();
    version8['purchase_items'] = version8['purchase_items']!.map((row) => {
      ...row, 'returned_quantity': 0,
    }).toList();
    version8['customer_returns'] = [];
    version8['customer_return_items'] = [];
    version8['supplier_returns'] = [];
    version8['supplier_return_items'] = [];
    version8['sales'] = version8['sales']!.map((row) {
      final compatible = Map<String, Object?>.from(row)..remove('customer_id');
      return compatible;
    }).toList();

    await database.transaction(
      (txn) => replaceBackupBusinessData(txn, version8),
    );
    expect(await database.query('purchases'), hasLength(1));
    expect(await database.query('purchase_items'), hasLength(1));
    expect(await database.query('customers'), isEmpty);
    expect(await database.query('customer_account_entries'), isEmpty);
    expect(
      (await database.query('sales')).single['customer_id'],
      isNull,
    );
    expect(
      (await database.query('purchases')).single['supplier_id'],
      ids['supplier_id'],
    );

    final version7 = {
      for (final entry in version8.entries)
        entry.key: entry.value.map((row) => Map<String, Object?>.from(row)).toList(),
    };
    version7['suppliers'] = [];
    version7['purchases'] = [];
    version7['purchase_items'] = [];
    version7['supplier_account_entries'] = [];
    version7['sale_items'] = version7['sale_items']!.map((row) => {
      ...row, 'returned_quantity': 0, 'returned_minor': 0,
    }).toList();
    version7['customer_returns'] = [];
    version7['customer_return_items'] = [];
    version7['supplier_returns'] = [];
    version7['supplier_return_items'] = [];

    await database.transaction(
      (txn) => replaceBackupBusinessData(txn, version7),
    );
    expect(await database.query('suppliers'), isEmpty);
    expect(await database.query('purchases'), isEmpty);
    expect(await database.query('purchase_items'), isEmpty);
    expect(await database.query('supplier_account_entries'), isEmpty);
    expect(await database.query('customers'), isEmpty);
    expect(await database.query('customer_account_entries'), isEmpty);
    expect(await database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

}
