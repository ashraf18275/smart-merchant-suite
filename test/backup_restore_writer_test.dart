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
      'unit_price_minor': 250,
      'unit_cost_minor': 125,
      'line_total_minor': 500,
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
      'unit_cost_minor': 125,
      'line_total_minor': 250,
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
}
