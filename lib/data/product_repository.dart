import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/product_store.dart';
import '../core/app_error.dart';
import '../domain/product.dart';
import '../domain/product_category.dart';
import '../domain/product_unit.dart';
import '../application/ports/catalog_store.dart';

Map<String, Object?> _productToRow(Product product) {
  final normalizedSku = product.sku?.trim();
  return {
    if (product.id != null) 'id': product.id,
    'name': product.name.trim(),
    'sku': normalizedSku == null || normalizedSku.isEmpty ? null : normalizedSku,
    'cost_minor': product.costMinor,
    'price_minor': product.priceMinor,
    'stock_quantity': product.stockQuantity,
    'category_id': product.categoryId,
    'unit_id': product.unitId,
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
      categoryId: row['category_id'] as int?,
      unitId: row['unit_id'] as int?,
      isActive: row['is_active'] == 1,
      createdAt: DateTime.parse(row['created_at']! as String).toLocal(),
    );

class ProductRepository implements ProductStore, CatalogStore {
  ProductRepository(this._db);

  final Database _db;

  Future<int> add(Product product) async {
    return _db.transaction((txn) async {
      final createdAt = product.createdAt ?? DateTime.now();
      final row = _productToRow(product);
      if (row['unit_id'] == null) {
        final units = await txn.query(
          'product_units',
          columns: ['id'],
          where: 'name = ? AND is_active = 1',
          whereArgs: ['قطعة'],
          limit: 1,
        );
        if (units.isEmpty) throw AppException('وحدة القياس الافتراضية غير موجودة');
        row['unit_id'] = units.single['id'];
      }
      final productId = await txn.insert('products', row);

      // The opening balance is a stock movement, not an unexplained balance.
      // Keep both writes in one transaction so the ledger and balance agree.
      if (product.stockQuantity > 0) {
        await txn.insert('inventory_movements', {
          'product_id': productId,
          'quantity_delta': product.stockQuantity,
          'reason': 'رصيد افتتاحي',
          'created_at': createdAt.toUtc().toIso8601String(),
        });
      }
      return productId;
    });
  }

  /// Updates editable product details without changing the stock balance.
  Future<void> update(Product product) async {
    final id = product.id;
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
        'category_id': product.categoryId,
        'unit_id': product.unitId,
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

  @override
  Future<List<ProductCategory>> categories({bool includeInactive = false}) async {
    final rows = await _db.query('product_categories',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'name COLLATE NOCASE ASC');
    return rows.map((row) => ProductCategory(
      id: row['id']! as int, name: row['name']! as String,
      isActive: row['is_active'] == 1,
    )).toList(growable: false);
  }

  @override
  Future<int> addCategory(String name) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم التصنيف مطلوب');
    return _db.insert('product_categories', {
      'name': value, 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> updateCategory({required int id, required String name}) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم التصنيف مطلوب');
    final changed = await _db.update('product_categories', {'name': value},
      where: 'id = ?', whereArgs: [id]);
    if (changed == 0) throw AppException('التصنيف غير موجود');
  }

  @override
  Future<void> setCategoryActive({required int id, required bool isActive}) async {
    final changed = await _db.update('product_categories',
      {'is_active': isActive ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    if (changed == 0) throw AppException('التصنيف غير موجود');
  }

  @override
  Future<List<ProductUnit>> units({bool includeInactive = false}) async {
    final rows = await _db.query('product_units',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'name COLLATE NOCASE ASC');
    return rows.map((row) => ProductUnit(
      id: row['id']! as int, name: row['name']! as String,
      abbreviation: row['abbreviation']! as String,
      allowsFraction: row['allows_fraction'] == 1,
      isActive: row['is_active'] == 1,
    )).toList(growable: false);
  }

  @override
  Future<int> addUnit({required String name, required String abbreviation,
    required bool allowsFraction}) async {
    final unitName = name.trim(), shortName = abbreviation.trim();
    if (unitName.isEmpty) throw AppException('اسم وحدة القياس مطلوب');
    if (shortName.isEmpty) throw AppException('اختصار وحدة القياس مطلوب');
    return _db.insert('product_units', {
      'name': unitName, 'abbreviation': shortName,
      'allows_fraction': allowsFraction ? 1 : 0, 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> updateUnit({required int id, required String name,
    required String abbreviation, required bool allowsFraction}) async {
    final unitName = name.trim(), shortName = abbreviation.trim();
    if (unitName.isEmpty) throw AppException('اسم وحدة القياس مطلوب');
    if (shortName.isEmpty) throw AppException('اختصار وحدة القياس مطلوب');
    final changed = await _db.update('product_units', {
      'name': unitName, 'abbreviation': shortName,
      'allows_fraction': allowsFraction ? 1 : 0,
    }, where: 'id = ?', whereArgs: [id]);
    if (changed == 0) throw AppException('وحدة القياس غير موجودة');
  }

  @override
  Future<void> setUnitActive({required int id, required bool isActive}) async {
    final rows = await _db.query('product_units', columns: ['name'],
      where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) throw AppException('وحدة القياس غير موجودة');
    if (!isActive && rows.single['name'] == 'قطعة') {
      throw AppException('لا يمكن إيقاف وحدة «قطعة» الافتراضية');
    }
    await _db.update('product_units', {'is_active': isActive ? 1 : 0},
      where: 'id = ?', whereArgs: [id]);
  }
}
