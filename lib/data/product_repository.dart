import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/product_store.dart';
import '../core/app_error.dart';
import '../core/quantity.dart';
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
      defaultWarehouseStock: row['default_warehouse_stock'] as int?,
      categoryId: row['category_id'] as int?,
      unitId: row['unit_id'] as int?,
      unitAllowsFraction: row['unit_allows_fraction'] == 1,
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
      final unitRows = await txn.query(
        'product_units',
        columns: ['allows_fraction'],
        where: 'id = ?',
        whereArgs: [row['unit_id']],
        limit: 1,
      );
      if (unitRows.isEmpty) throw AppException('وحدة القياس غير موجودة');
      if (unitRows.single['allows_fraction'] != 1 &&
          product.stockQuantity % Quantity.scale != 0) {
        throw AppException('وحدة القياس المحددة لا تقبل الكميات الكسرية');
      }
      final productId = await txn.insert('products', row);
      final defaultWarehouses = await txn.rawQuery('''
        SELECT w.id FROM warehouses w
        JOIN branches b ON b.id = w.branch_id
        WHERE w.name = 'المخزن الرئيسي' AND b.name = 'الفرع الرئيسي'
          AND w.is_active = 1 AND b.is_active = 1
        LIMIT 1
      ''');
      if (defaultWarehouses.isEmpty) {
        throw AppException('المخزن الرئيسي الافتراضي غير موجود أو غير نشط');
      }
      final warehouseId = defaultWarehouses.single['id']! as int;
      final stamp = createdAt.toUtc().toIso8601String();
      await txn.insert('product_warehouse_stock', {
        'product_id': productId,
        'warehouse_id': warehouseId,
        'quantity': product.stockQuantity,
        'updated_at': stamp,
      });
      if (product.stockQuantity > 0) {
        await txn.insert('inventory_movements', {
          'product_id': productId,
          'warehouse_id': warehouseId,
          'quantity_delta': product.stockQuantity,
          'reason': 'رصيد افتتاحي',
          'created_at': stamp,
        });
      }
      return productId;
    });
  }

  /// Updates editable product details without changing the stock balance.
  Future<void> update(Product product) async {
    final id = product.id;
    final normalizedSku = product.sku?.trim();
    await _db.transaction((txn) async {
      final current = await txn.query(
        'products',
        columns: ['stock_quantity', 'unit_id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (current.isEmpty) throw AppException('المنتج غير موجود');
      final targetUnitId = product.unitId ?? (current.single['unit_id'] as int?);
      final unitRows = await txn.query(
        'product_units',
        columns: ['allows_fraction'],
        where: 'id = ?',
        whereArgs: [targetUnitId],
        limit: 1,
      );
      if (unitRows.isEmpty) throw AppException('وحدة القياس غير موجودة');
      final currentUnitId = current.single['unit_id'] as int?;
      if (targetUnitId != currentUnitId) {
        final historicalSales = await txn.query(
          'sale_items',
          columns: ['id'],
          where: 'product_id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (historicalSales.isNotEmpty) {
          throw AppException('لا يمكن تغيير وحدة المنتج بعد تسجيل مبيعات سابقة');
        }
      }
      if (unitRows.single['allows_fraction'] != 1) {
        final fractionalBalances = await txn.rawQuery('''
          SELECT
            (SELECT COUNT(*) FROM products WHERE id = ? AND stock_quantity % 1000 != 0) +
            (SELECT COUNT(*) FROM product_warehouse_stock WHERE product_id = ? AND quantity % 1000 != 0) AS count
        ''', [id, id]);
        if ((fractionalBalances.single['count'] as num).toInt() > 0) {
          throw AppException('لا يمكن اختيار وحدة لا تقبل الكسور مع وجود رصيد كسري');
        }
      }
      final changed = await txn.update('products', {
        'name': product.name.trim(),
        'sku': normalizedSku == null || normalizedSku.isEmpty ? null : normalizedSku,
        'cost_minor': product.costMinor,
        'price_minor': product.priceMinor,
        'category_id': product.categoryId,
        'unit_id': targetUnitId,
      }, where: 'id = ?', whereArgs: [id]);
      if (changed == 0) throw AppException('المنتج غير موجود');
    });
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
    if (!includeInactive) conditions.add('p.is_active = 1');
    if (normalized.isNotEmpty) {
      conditions.add('(name LIKE ? OR sku LIKE ?)');
      args.addAll(['%$normalized%', '%$normalized%']);
    }
    final rows = await _db.rawQuery('''
      SELECT p.*, COALESCE(u.allows_fraction, 0) AS unit_allows_fraction,
        COALESCE((
          SELECT s.quantity
          FROM product_warehouse_stock s
          JOIN warehouses w ON w.id = s.warehouse_id
          JOIN branches b ON b.id = w.branch_id
          WHERE s.product_id = p.id
            AND w.name = 'المخزن الرئيسي'
            AND b.name = 'الفرع الرئيسي'
          LIMIT 1
        ), 0) AS default_warehouse_stock
      FROM products p
      LEFT JOIN product_units u ON u.id = p.unit_id
      ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
      ORDER BY p.name COLLATE NOCASE ASC
    ''', args);
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
      final products = await txn.rawQuery('''
        SELECT p.id, COALESCE(u.allows_fraction, 0) AS allows_fraction
        FROM products p LEFT JOIN product_units u ON u.id = p.unit_id
        WHERE p.id = ? AND p.is_active = 1 LIMIT 1
      ''', [productId]);
      if (products.isEmpty) throw AppException('المنتج غير موجود أو غير نشط');
      if (products.single['allows_fraction'] != 1 &&
          quantityDelta % Quantity.scale != 0) {
        throw AppException('وحدة قياس المنتج لا تقبل الكميات الكسرية');
      }
      final warehouses = await txn.rawQuery('''
        SELECT w.id FROM warehouses w
        JOIN branches b ON b.id = w.branch_id
        WHERE w.name = 'المخزن الرئيسي' AND b.name = 'الفرع الرئيسي'
          AND w.is_active = 1 AND b.is_active = 1
        LIMIT 1
      ''');
      if (warehouses.isEmpty) throw AppException('المخزن الرئيسي الافتراضي غير موجود');
      final warehouseId = warehouses.single['id']! as int;
      final balances = await txn.query(
        'product_warehouse_stock',
        columns: ['id', 'quantity'],
        where: 'product_id = ? AND warehouse_id = ?',
        whereArgs: [productId, warehouseId],
        limit: 1,
      );
      final current = balances.isEmpty ? 0 : balances.single['quantity']! as int;
      final next = current + quantityDelta;
      if (next < 0) throw AppException('الكمية غير كافية؛ لا يسمح بالمخزون السالب');
      final stamp = DateTime.now().toUtc().toIso8601String();
      if (balances.isEmpty) {
        await txn.insert('product_warehouse_stock', {
          'product_id': productId,
          'warehouse_id': warehouseId,
          'quantity': next,
          'updated_at': stamp,
        });
      } else {
        await txn.update('product_warehouse_stock', {
          'quantity': next,
          'updated_at': stamp,
        }, where: 'id = ?', whereArgs: [balances.single['id']]);
      }
      final totals = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total FROM product_warehouse_stock WHERE product_id = ?',
        [productId],
      );
      await txn.update('products', {'stock_quantity': totals.single['total']},
          where: 'id = ?', whereArgs: [productId]);
      await txn.insert('inventory_movements', {
        'product_id': productId,
        'warehouse_id': warehouseId,
        'quantity_delta': quantityDelta,
        'reason': reason.trim(),
        'created_at': stamp,
      });
    });
  }

  @override
  Future<List<ProductCategory>> categories({bool includeInactive = false}) async {
    final rows = await _db.query('product_categories',
        where: includeInactive ? null : 'is_active = 1',
        orderBy: 'name COLLATE NOCASE ASC');
    return rows.map((row) => ProductCategory(
      id: row['id']! as int,
      name: row['name']! as String,
      isActive: row['is_active'] == 1,
    )).toList(growable: false);
  }

  @override
  Future<int> addCategory(String name) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم التصنيف مطلوب');
    return _db.insert('product_categories', {
      'name': value,
      'is_active': 1,
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
      id: row['id']! as int,
      name: row['name']! as String,
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
    final current = await _db.query('product_units', columns: ['name', 'allows_fraction'],
      where: 'id = ?', whereArgs: [id], limit: 1);
    if (current.isEmpty) throw AppException('وحدة القياس غير موجودة');
    if (current.single['name'] == 'قطعة' && unitName != 'قطعة') {
      throw AppException('لا يمكن تغيير اسم وحدة «قطعة» الافتراضية');
    }
    if (!allowsFraction && current.single['allows_fraction'] == 1) {
      final fractionalBalances = await _db.rawQuery('''
        SELECT
          (SELECT COUNT(*) FROM products p WHERE p.unit_id = ? AND p.stock_quantity % 1000 != 0) +
          (SELECT COUNT(*) FROM product_warehouse_stock s JOIN products p ON p.id = s.product_id
            WHERE p.unit_id = ? AND s.quantity % 1000 != 0) AS count
      ''', [id, id]);
      if ((fractionalBalances.single['count'] as num).toInt() > 0) {
        throw AppException('لا يمكن إيقاف الكسور قبل تسوية أرصدة المنتجات إلى كميات صحيحة');
      }
    }
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