import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/sales_store.dart';
import '../core/app_error.dart';
import '../domain/sale_record.dart';

class SalesRepository implements SalesStore {
  SalesRepository(this._db);
  final Database _db;

  /// Creates a multi-item invoice, deducts stock and writes movement audit rows
  /// in one transaction. Keys are product IDs and values are positive quantities.
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
  }) async {
    return _db.transaction((txn) async {
      final items = <Map<String, int>>[];
      var total = 0;
      for (final entry in quantities.entries) {
        final rows = await txn.query(
          'products',
          columns: ['cost_minor', 'price_minor', 'stock_quantity'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [entry.key],
          limit: 1,
        );
        if (rows.isEmpty) throw AppException('أحد المنتجات غير موجود أو غير نشط');
        final product = rows.single;
        final stock = product['stock_quantity']! as int;
        if (stock < entry.value) throw AppException('الكمية غير كافية لأحد المنتجات.');
        final price = product['price_minor']! as int;
        final cost = product['cost_minor']! as int;
        final lineTotal = price * entry.value;
        total += lineTotal;
        items.add({
          'productId': entry.key,
          'quantity': entry.value,
          'stock': stock,
          'price': price,
          'cost': cost,
          'lineTotal': lineTotal,
        });
      }
      if (paidMinor > total) throw AppException('المبلغ المدفوع أكبر من إجمالي الفاتورة');

      final createdAt = DateTime.now().toUtc().toIso8601String();
      final saleId = await txn.insert('sales', {
        'total_minor': total,
        'paid_minor': paidMinor,
        'created_at': createdAt,
      });
      for (final item in items) {
        final productId = item['productId']!;
        final quantity = item['quantity']!;
        await txn.insert('sale_items', {
          'sale_id': saleId,
          'product_id': productId,
          'quantity': quantity,
          'unit_price_minor': item['price']!,
          'unit_cost_minor': item['cost']!,
          'line_total_minor': item['lineTotal']!,
        });
        await txn.update('products', {
          'stock_quantity': item['stock']! - quantity,
        }, where: 'id = ?', whereArgs: [productId]);
        await txn.insert('inventory_movements', {
          'product_id': productId,
          'quantity_delta': -quantity,
          'reason': 'بيع فاتورة رقم $saleId',
          'created_at': createdAt,
        });
      }
      return saleId;
    });
  }

  Future<List<SaleRecord>> all() async {
    final rows = await _db.rawQuery('''
      SELECT s.id, s.total_minor, s.paid_minor, s.created_at,
             COUNT(i.id) AS item_count
      FROM sales s
      LEFT JOIN sale_items i ON i.sale_id = s.id
      GROUP BY s.id
      ORDER BY s.id DESC
    ''');
    return rows.map((row) => SaleRecord(
      id: row['id']! as int,
      totalMinor: row['total_minor']! as int,
      paidMinor: row['paid_minor']! as int,
      createdAt: DateTime.parse(row['created_at']! as String).toLocal(),
      itemCount: row['item_count']! as int,
    )).toList(growable: false);
  }
}
