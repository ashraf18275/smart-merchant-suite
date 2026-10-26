import 'package:sqflite_common/sqlite_api.dart';

class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.totalMinor,
    required this.paidMinor,
    required this.createdAt,
    required this.itemCount,
  });

  final int id;
  final int totalMinor;
  final int paidMinor;
  final DateTime createdAt;
  final int itemCount;

  int get remainingMinor => totalMinor - paidMinor;
}

class SalesRepository {
  SalesRepository(this._db);
  final Database _db;

  /// Records a one-product invoice atomically with its stock movement.
  Future<int> createSingleProductSale({
    required int productId,
    required int quantity,
    required int paidMinor,
  }) async {
    if (quantity <= 0) throw ArgumentError('كمية البيع يجب أن تكون أكبر من صفر');
    if (paidMinor < 0) throw ArgumentError('المبلغ المدفوع لا يمكن أن يكون سالبًا');

    return _db.transaction((txn) async {
      final rows = await txn.query(
        'products',
        columns: ['name', 'cost_minor', 'price_minor', 'stock_quantity'],
        where: 'id = ? AND is_active = 1',
        whereArgs: [productId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('المنتج غير موجود أو غير نشط');
      final product = rows.single;
      final stock = product['stock_quantity']! as int;
      final price = product['price_minor']! as int;
      final cost = product['cost_minor']! as int;
      if (stock < quantity) throw StateError('الكمية غير كافية لإتمام البيع');
      final total = price * quantity;
      if (paidMinor > total) throw ArgumentError('المبلغ المدفوع أكبر من إجمالي الفاتورة');
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final saleId = await txn.insert('sales', {
        'total_minor': total,
        'paid_minor': paidMinor,
        'created_at': createdAt,
      });
      await txn.insert('sale_items', {
        'sale_id': saleId,
        'product_id': productId,
        'quantity': quantity,
        'unit_price_minor': price,
        'unit_cost_minor': cost,
        'line_total_minor': total,
      });
      await txn.update(
        'products',
        {'stock_quantity': stock - quantity},
        where: 'id = ?',
        whereArgs: [productId],
      );
      await txn.insert('inventory_movements', {
        'product_id': productId,
        'quantity_delta': -quantity,
        'reason': 'بيع فاتورة رقم $saleId',
        'created_at': createdAt,
      });
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
