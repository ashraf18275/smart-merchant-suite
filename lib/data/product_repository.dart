import 'package:sqflite_common/sqlite_api.dart';

/// Creates the first version of the local schema.
Future<void> createLocalSchema(Database db) async {
  await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL CHECK (length(trim(name)) > 0),
      sku TEXT UNIQUE,
      cost_minor INTEGER NOT NULL CHECK (cost_minor >= 0),
      price_minor INTEGER NOT NULL CHECK (price_minor >= 0),
      stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE inventory_movements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id INTEGER NOT NULL,
      quantity_delta INTEGER NOT NULL CHECK (quantity_delta != 0),
      reason TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (product_id) REFERENCES products (id)
    )
  ''');

  await db.execute('''
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
  ''');

  await db.insert('schema_migrations', {
    'version': 1,
    'applied_at': DateTime.now().toUtc().toIso8601String(),
  });
}

class Product {
  const Product({
    this.id,
    required this.name,
    this.sku,
    required this.costMinor,
    required this.priceMinor,
    this.stockQuantity = 0,
    this.isActive = true,
    this.createdAt,
  });

  final int? id;
  final String name;
  final String? sku;

  /// Money is stored as integer minor units (for example, piastres), never double.
  final int costMinor;
  final int priceMinor;
  final int stockQuantity;
  final bool isActive;
  final DateTime? createdAt;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name.trim(),
        'sku': (sku == null || sku.trim().isEmpty) ? null : sku.trim(),
        'cost_minor': costMinor,
        'price_minor': priceMinor,
        'stock_quantity': stockQuantity,
        'is_active': isActive ? 1 : 0,
        'created_at':
            (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
      };

  factory Product.fromMap(Map<String, Object?> map) => Product(
        id: map['id']! as int,
        name: map['name']! as String,
        sku: map['sku'] as String?,
        costMinor: map['cost_minor']! as int,
        priceMinor: map['price_minor']! as int,
        stockQuantity: map['stock_quantity']! as int,
        isActive: map['is_active'] == 1,
        createdAt: DateTime.parse(map['created_at']! as String).toLocal(),
      );
}

class ProductRepository {
  ProductRepository(this._db);

  final Database _db;

  Future<int> add(Product product) async {
    final name = product.name.trim();
    if (name.isEmpty) {
      throw ArgumentError('اسم المنتج مطلوب');
    }
    if (product.costMinor < 0 || product.priceMinor < 0) {
      throw ArgumentError('السعر والتكلفة لا يمكن أن يكونا سالبين');
    }
    if (product.stockQuantity < 0) {
      throw ArgumentError('كمية المخزون لا يمكن أن تكون سالبة');
    }

    return _db.insert('products', product.toMap());
  }

  Future<List<Product>> all({String search = ''}) async {
    final normalized = search.trim();
    final rows = await _db.query(
      'products',
      where: normalized.isEmpty ? null : 'name LIKE ? OR sku LIKE ?',
      whereArgs: normalized.isEmpty
          ? null
          : <Object?>['%$normalized%', '%$normalized%'],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(Product.fromMap).toList(growable: false);
  }

  /// Applies stock change and writes its audit movement atomically.
  /// Negative stock is deliberately rejected in the first version.
  Future<void> changeStock({
    required int productId,
    required int quantityDelta,
    required String reason,
  }) async {
    if (quantityDelta == 0) {
      throw ArgumentError('يجب أن تكون حركة المخزون أكبر من صفر أو أقل من صفر');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError('سبب حركة المخزون مطلوب');
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
        throw StateError('المنتج غير موجود أو غير نشط');
      }

      final current = rows.single['stock_quantity']! as int;
      final next = current + quantityDelta;
      if (next < 0) {
        throw StateError('الكمية غير كافية؛ لا يسمح بالمخزون السالب');
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
