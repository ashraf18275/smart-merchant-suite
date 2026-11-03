import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/data/backup_schema.dart';
import 'package:smart_merchant_suite/data/backup_restore_writer.dart';
import 'package:smart_merchant_suite/data/backup_snapshot.dart';
import 'package:smart_merchant_suite/data/migrations/local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('creates a consistent file snapshot with committed WAL data and all relationships', () async {
    final directory = await Directory.systemTemp.createTemp('merchant_backup_test_');
    final sourcePath = '${directory.path}/source.db';
    final snapshotPath = '${directory.path}/snapshot.db';
    Database? source;
    Database? snapshot;
    Database? restored;

    try {
      source = await databaseFactoryFfi.openDatabase(sourcePath);
      await source.execute('PRAGMA foreign_keys = ON');
      await source.rawQuery('PRAGMA journal_mode = WAL');
      await createLocalSchema(source);

      final stamp = DateTime.utc(2026, 11, 4).toIso8601String();
      final branch = (await source.query('branches')).single;
      final warehouse = (await source.query('warehouses')).single;
      final unit = (await source.query('product_units')).single;
      final supplierId = await source.insert('suppliers', {
        'name': 'مورد النسخة',
        'is_active': 1,
        'created_at': stamp,
      });
      final customerId = await source.insert('customers', {
        'name': 'عميل النسخة',
        'is_active': 1,
        'created_at': stamp,
      });
      final productId = await source.insert('products', {
        'name': 'منتج النسخة',
        'cost_minor': 100,
        'price_minor': 200,
        'stock_quantity': 2000,
        'unit_id': unit['id'],
        'is_active': 1,
        'created_at': stamp,
      });
      await source.insert('product_warehouse_stock', {
        'product_id': productId,
        'warehouse_id': warehouse['id'],
        'quantity': 2000,
        'updated_at': stamp,
      });
      final saleId = await source.insert('sales', {
        'total_minor': 400,
        'paid_minor': 200,
        'warehouse_id': warehouse['id'],
        'customer_id': customerId,
        'created_at': stamp,
      });
      await source.insert('sale_items', {
        'sale_id': saleId,
        'product_id': productId,
        'quantity': 2000,
        'unit_price_minor': 200,
        'unit_cost_minor': 100,
        'line_total_minor': 400,
      });
      await source.insert('expenses', {
        'description': 'مصروف النسخة',
        'category': 'تشغيل',
        'amount_minor': 50,
        'created_at': stamp,
      });
      await source.insert('inventory_movements', {
        'product_id': productId,
        'warehouse_id': warehouse['id'],
        'quantity_delta': 2000,
        'reason': 'رصيد افتتاحي',
        'created_at': stamp,
      });
      final purchaseId = await source.insert('purchases', {
        'supplier_id': supplierId,
        'warehouse_id': warehouse['id'],
        'total_minor': 300,
        'paid_minor': 100,
        'created_at': stamp,
      });
      await source.insert('purchase_items', {
        'purchase_id': purchaseId,
        'product_id': productId,
        'quantity': 2000,
        'unit_cost_minor': 150,
        'line_total_minor': 300,
      });
      await source.insert('supplier_account_entries', {
        'supplier_id': supplierId,
        'amount_minor': 300,
        'entry_type': 'purchase',
        'reference_id': purchaseId,
        'note': 'فاتورة شراء',
        'created_at': stamp,
      });
      await source.insert('customer_account_entries', {
        'customer_id': customerId,
        'amount_minor': 200,
        'entry_type': 'sale',
        'reference_id': saleId,
        'note': 'فاتورة بيع',
        'created_at': stamp,
      });

      // The source is intentionally left in WAL mode with committed writes.
      await createSqliteBackupSnapshot(source, snapshotPath);
      expect(await File(snapshotPath).exists(), isTrue);

      snapshot = await databaseFactoryFfi.openDatabase(
        snapshotPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final integrity = await snapshot.rawQuery('PRAGMA integrity_check');
      expect(integrity.first.values.first, 'ok');
      expect(await snapshot.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      for (final table in BackupSchema.restoreInsertOrder) {
        expect(
          await snapshot.query(table, orderBy: 'id ASC'),
          equals(await source.query(table, orderBy: 'id ASC')),
          reason: 'snapshot must contain the committed contents of $table',
        );
      }
      expect(
        (await snapshot.query('branches')).single['id'],
        branch['id'],
      );
      expect(
        (await snapshot.query('sales')).single['customer_id'],
        customerId,
      );
      expect(
        (await snapshot.query('purchases')).single['supplier_id'],
        supplierId,
      );

      // Exercise the complete file-backup -> restore path, not just snapshot
      // readability. Restore into a separate database with the current schema.
      restored = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await restored.execute('PRAGMA foreign_keys = ON');
      await createLocalSchema(restored);
      final backupData = <String, List<Map<String, Object?>>>{};
      for (final table in BackupSchema.restoreInsertOrder) {
        backupData[table] = await snapshot.query(table, orderBy: 'id ASC');
      }
      await restored.transaction(
        (txn) => replaceBackupBusinessData(txn, backupData),
      );

      for (final table in BackupSchema.restoreInsertOrder) {
        expect(
          await restored.query(table, orderBy: 'id ASC'),
          equals(backupData[table]),
          reason: 'restored database must match backup table $table',
        );
      }
      expect(await restored.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      if (restored != null) await restored.close();
      if (snapshot != null) await snapshot.close();
      if (source != null) await source.close();
      await directory.delete(recursive: true);
    }
  });
}
