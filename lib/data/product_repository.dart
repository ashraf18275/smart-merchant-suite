import 'package:sqflite_common/sqlite_api.dart';

import '../core/app_error.dart';
import '../domain/product.dart';

Map<String, Object?> _productToRow(Product product) {
  final normalizedSku = product.sku?.trim();
  return {
    if (product.id != null) 'id': product.id,
    'name': product.name.trim(),
    'sku': normalizedSku == null || normalizedSku.isEmpty ? null : normalizedSku,
    'cost_minor': product.costMinor,
    'price_minor': product.priceMinor,
    'stock_quantity': product.stockQuantity,
    'is_active': product.isActive ? 1 : 0,
    'created_at':
        (product.createdAt ?? DateTime.now()).toUtc().toIso8601String(),
  };
}

Product _productFromRow(Map<String, Object?> row) => Product(
      id: row['id']! as int,
      name: row['name']! as String,
      sku: row['sku'] as String?,
      costMinor: row['cost_minor']! as int,
      priceMinor: row['price_minor']! as int,
      stockQuantity: row['stock_quantity']! as int,
      isActive: row['is_active'] == 1,
      createdAt: DateTime.parse(row['created_at']! as String).toLocal(),
    );

class ProductRepository {
  ProductRepository(this._db);

  final Database _db;

  Future<int> add(Product product) async {
    final name = product.name.trim();
    if (name.isEmpty) {
      throw AppException('اسم المنتج مطلوب');
    }
    if (product.costMinor < 0 || product.priceMinor < 0) {
      throw AppException('السعر والتكلفة لا يمكن أن يكونا سالبين');
    }
    if (product.stockQuantity < 0) {
      throw AppException('كمية المخزون لا يمكن أن تكون سالبة');
    }

    return _db.insert('products', _productToRow(product));
  }

  /// Updates editable product details without changing the stock balance.
  Future<void> update(Product product) async {
    final id = product.id;
    if (id == null) {
      throw AppException('معرّف المنتج مطلوب للتعديل');
    }
    if (product.name.trim().isEmpty) {
      throw AppException('اسم المنتج مطلوب');
    }
    if (product.costMinor < 0 || product.priceMinor < 0) {
      throw AppException('السعر والتكلفة لا يمكن أن يكونا سالبين');
    }

    final normalizedSku = product.sku?.trim();
    final changed = await _db.update(
      'products',
      {
        'name': product.name.trim(),
        'sku': normalizedSku == null || normalizedSku.isEmpty
            ? null
            : normalizedSku,
        'cost_minor': product.costMinor,
        'price_minor': product.priceMinor,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw AppException('المنتج غير موجود');
    }
  }

  /// Deactivates/reactivates a product without deleting its history or stock.
  Future<void> setActive({required int productId, required bool isActive}) async {
    final changed = await _db.update(
      'products',
      {'is_active': isActive ? 1 : 0},
      where: 'id = ?',
      whereArgs: [productId],
    );
    if (changed == 0) {
      throw AppException('المنتج غير موجود');
    }
  }

  Future<List<Product>> all({
    String search = '',
    bool includeInactive = false,
  }) async {
    final normalized = search.trim();
    final conditions = <String>[];
    final args = <Object?>[];
    if (!includeInactive) conditions.add('is_active = 1');
    if (normalized.isNotEmpty) {
      conditions.add('(name LIKE ? OR sku LIKE ?)');
      args.addAll(['%$normalized%', '%$normalized%']);
    }
    final rows = await _db.query(
      'products',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(_productFromRow).toList(growable: false);
  }

  /// Applies stock change and writes its audit movement atomically.
  /// Negative stock is deliberately rejected in the first version.
  Future<void> changeStock({
    required int productId,
    required int quantityDelta,
    required String reason,
  }) async {
    if (quantityDelta == 0) {
      throw AppException('يجب أن تكون حركة المخزون أكبر من صفر أو أقل من صفر');
    }
    if (reason.trim().isEmpty) {
      throw AppException('سبب حركة المخزون مطلوب');
    }

    await _db.transaction((txn) async {
      final rows = await txn.query(
        'products',
        columns: ['stock_quantity'],
        where: 'id = ? AND is_active = 1',
        whereArgs: [productId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw AppException('المنتج غير موجود أو غير نشط');
      }

      final current = rows.single['stock_quantity']! as int;
      final next = current + quantityDelta;
      if (next < 0) {
        throw AppException('الكمية غير كافية؛ لا يسمح بالمخزون السالب');
      }

      await txn.update(
        'products',
        {'stock_quantity': next},
        where: 'id = ?',
        whereArgs: [productId],
      );
      await txn.insert('inventory_movements', {
        'product_id': productId,
        'quantity_delta': quantityDelta,
        'reason': reason.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }
}
