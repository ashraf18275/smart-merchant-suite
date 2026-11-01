import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/branch_warehouse_store.dart';
import '../core/app_error.dart';
import '../domain/branch.dart';
import '../domain/warehouse.dart';
import '../domain/warehouse_stock.dart';

class WarehouseRepository implements BranchWarehouseStore {
  WarehouseRepository(this._db);
  final Database _db;

  @override
  Future<List<Branch>> branches({bool includeInactive = false}) async {
    final rows = await _db.query(
      'branches',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map((row) => Branch(
      id: row['id']! as int,
      name: row['name']! as String,
      address: row['address'] as String?,
      phone: row['phone'] as String?,
      isActive: row['is_active'] == 1,
    )).toList(growable: false);
  }

  @override
  Future<int> addBranch({required String name, String? address, String? phone}) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم الفرع مطلوب');
    try {
      return await _db.insert('branches', {
        'name': value,
        'address': _optional(address),
        'phone': _optional(phone),
        'is_active': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      throw AppException('اسم الفرع مستخدم بالفعل أو تعذر حفظه');
    }
  }

  @override
  Future<void> updateBranch({
    required int id,
    required String name,
    String? address,
    String? phone,
  }) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم الفرع مطلوب');
    final currentBranch = await _db.query('branches', columns: ['name'],
      where: 'id = ?', whereArgs: [id], limit: 1);
    if (currentBranch.isEmpty) throw AppException('الفرع غير موجود');
    if (currentBranch.single['name'] == 'الفرع الرئيسي' && value != 'الفرع الرئيسي') {
      throw AppException('لا يمكن تغيير اسم الفرع الرئيسي الافتراضي');
    }
    try {
      final changed = await _db.update('branches', {
        'name': value,
        'address': _optional(address),
        'phone': _optional(phone),
      }, where: 'id = ?', whereArgs: [id]);
      if (changed == 0) throw AppException('الفرع غير موجود');
    } on AppException {
      rethrow;
    } catch (_) {
      throw AppException('اسم الفرع مستخدم بالفعل أو تعذر تعديله');
    }
  }

  @override
  Future<void> setBranchActive({required int id, required bool isActive}) async {
    if (!isActive) {
      final activeWarehouses = await _db.query(
        'warehouses',
        columns: ['id'],
        where: 'branch_id = ? AND is_active = 1',
        whereArgs: [id],
        limit: 1,
      );
      if (activeWarehouses.isNotEmpty) {
        throw AppException('أوقف مخازن الفرع أولًا قبل إيقاف الفرع');
      }
      final branch = await _db.query('branches', columns: ['name'],
        where: 'id = ?', whereArgs: [id], limit: 1);
      if (branch.isEmpty) throw AppException('الفرع غير موجود');
      if (branch.single['name'] == 'الفرع الرئيسي') {
        throw AppException('لا يمكن إيقاف الفرع الرئيسي الافتراضي');
      }
    }
    final changed = await _db.update('branches',
      {'is_active': isActive ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    if (changed == 0) throw AppException('الفرع غير موجود');
  }

  @override
  Future<List<Warehouse>> warehouses({
    int? branchId,
    bool includeInactive = false,
  }) async {
    final conditions = <String>[];
    final args = <Object?>[];
    if (!includeInactive) conditions.add('w.is_active = 1 AND b.is_active = 1');
    if (branchId != null) {
      conditions.add('w.branch_id = ?');
      args.add(branchId);
    }
    final rows = await _db.rawQuery('''
      SELECT w.id, w.branch_id, w.name, w.is_active, b.name AS branch_name
      FROM warehouses w
      JOIN branches b ON b.id = w.branch_id
      ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
      ORDER BY b.name COLLATE NOCASE, w.name COLLATE NOCASE
    ''', args);
    return rows.map((row) => Warehouse(
      id: row['id']! as int,
      branchId: row['branch_id']! as int,
      branchName: row['branch_name']! as String,
      name: row['name']! as String,
      isActive: row['is_active'] == 1,
    )).toList(growable: false);
  }

  @override
  Future<int> addWarehouse({required int branchId, required String name}) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم المخزن مطلوب');
    final branches = await _db.query('branches', columns: ['id'],
      where: 'id = ? AND is_active = 1', whereArgs: [branchId], limit: 1);
    if (branches.isEmpty) throw AppException('الفرع غير موجود أو غير نشط');
    try {
      return await _db.insert('warehouses', {
        'branch_id': branchId,
        'name': value,
        'is_active': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      throw AppException('اسم المخزن مستخدم داخل هذا الفرع أو تعذر حفظه');
    }
  }

  @override
  Future<void> updateWarehouse({required int id, required String name}) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم المخزن مطلوب');
    final currentWarehouse = await _db.rawQuery('''
      SELECT w.name, b.name AS branch_name FROM warehouses w
      JOIN branches b ON b.id = w.branch_id WHERE w.id = ? LIMIT 1
    ''', [id]);
    if (currentWarehouse.isEmpty) throw AppException('المخزن غير موجود');
    if (currentWarehouse.single['name'] == 'المخزن الرئيسي' &&
        currentWarehouse.single['branch_name'] == 'الفرع الرئيسي' &&
        value != 'المخزن الرئيسي') {
      throw AppException('لا يمكن تغيير اسم المخزن الرئيسي الافتراضي');
    }
    try {
      final changed = await _db.update('warehouses', {'name': value},
        where: 'id = ?', whereArgs: [id]);
      if (changed == 0) throw AppException('المخزن غير موجود');
    } on AppException {
      rethrow;
    } catch (_) {
      throw AppException('اسم المخزن مستخدم داخل الفرع أو تعذر تعديله');
    }
  }

  @override
  Future<void> setWarehouseActive({required int id, required bool isActive}) async {
    final rows = await _db.query(
      'warehouses',
      columns: ['name'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw AppException('المخزن غير موجود');
    if (!isActive) {
      if (rows.single['name'] == 'المخزن الرئيسي') {
        final branch = await _db.rawQuery('''
          SELECT b.name AS branch_name FROM warehouses w
          JOIN branches b ON b.id = w.branch_id WHERE w.id = ?
        ''', [id]);
        if (branch.single['branch_name'] == 'الفرع الرئيسي') {
          throw AppException('لا يمكن إيقاف المخزن الرئيسي الافتراضي');
        }
      }
      final balances = await _db.query(
        'product_warehouse_stock',
        columns: ['id'],
        where: 'warehouse_id = ? AND quantity > 0',
        whereArgs: [id],
        limit: 1,
      );
      if (balances.isNotEmpty) {
        throw AppException('انقل الكميات الموجودة في المخزن قبل إيقافه');
      }
    }
    await _db.update('warehouses', {'is_active': isActive ? 1 : 0},
      where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<WarehouseStock>> stock({required int warehouseId}) async {
    final rows = await _db.rawQuery('''
      SELECT p.id AS product_id, p.name AS product_name, p.sku,
             COALESCE(u.abbreviation, u.name, 'قطعة') AS unit_name,
             COALESCE(s.quantity, 0) AS quantity
      FROM products p
      LEFT JOIN product_warehouse_stock s
        ON s.product_id = p.id AND s.warehouse_id = ?
      LEFT JOIN product_units u ON u.id = p.unit_id
      WHERE p.is_active = 1
      ORDER BY p.name COLLATE NOCASE
    ''', [warehouseId]);
    return rows.map((row) => WarehouseStock(
      productId: row['product_id']! as int,
      productName: row['product_name']! as String,
      sku: row['sku'] as String?,
      unitName: row['unit_name']! as String,
      quantity: row['quantity']! as int,
    )).toList(growable: false);
  }

  @override
  Future<void> adjustStock({
    required int warehouseId,
    required int productId,
    required int quantityDelta,
    required String reason,
  }) async {
    if (quantityDelta == 0) throw AppException('الكمية المطلوب تعديلها لا يمكن أن تكون صفرًا');
    final note = reason.trim();
    if (note.isEmpty) throw AppException('سبب حركة المخزون مطلوب');
    await _db.transaction((txn) async {
      await _ensureActiveWarehouse(txn, warehouseId);
      final products = await txn.query('products', columns: ['id'],
        where: 'id = ? AND is_active = 1', whereArgs: [productId], limit: 1);
      if (products.isEmpty) throw AppException('المنتج غير موجود أو غير نشط');
      final current = await _balance(txn, productId, warehouseId);
      final next = current + quantityDelta;
      if (next < 0) throw AppException('لا يمكن أن تصبح كمية المخزن سالبة');
      await _writeBalance(txn, productId, warehouseId, next);
      await _writeAggregate(txn, productId);
      await _writeMovement(txn, productId, warehouseId, quantityDelta, note);
    });
  }

  @override
  Future<void> transferStock({
    required int productId,
    required int fromWarehouseId,
    required int toWarehouseId,
    required int quantity,
    required String reason,
  }) async {
    if (fromWarehouseId == toWarehouseId) throw AppException('اختر مخزنين مختلفين للتحويل');
    if (quantity <= 0) throw AppException('كمية التحويل يجب أن تكون أكبر من صفر');
    final note = reason.trim();
    if (note.isEmpty) throw AppException('سبب التحويل مطلوب');
    await _db.transaction((txn) async {
      await _ensureActiveWarehouse(txn, fromWarehouseId);
      await _ensureActiveWarehouse(txn, toWarehouseId);
      final products = await txn.query('products', columns: ['id'],
        where: 'id = ? AND is_active = 1', whereArgs: [productId], limit: 1);
      if (products.isEmpty) throw AppException('المنتج غير موجود أو غير نشط');
      final available = await _balance(txn, productId, fromWarehouseId);
      if (available < quantity) throw AppException('الكمية المتاحة في المخزن المصدر غير كافية');
      final destination = await _balance(txn, productId, toWarehouseId);
      await _writeBalance(txn, productId, fromWarehouseId, available - quantity);
      await _writeBalance(txn, productId, toWarehouseId, destination + quantity);
      final stamp = DateTime.now().toUtc().toIso8601String();
      await _writeMovement(txn, productId, fromWarehouseId, -quantity, 'تحويل إلى مخزن آخر: $note', stamp);
      await _writeMovement(txn, productId, toWarehouseId, quantity, 'تحويل من مخزن آخر: $note', stamp);
      await _writeAggregate(txn, productId);
    });
  }

  Future<void> _ensureActiveWarehouse(Transaction txn, int warehouseId) async {
    final rows = await txn.rawQuery('''
      SELECT w.id FROM warehouses w
      JOIN branches b ON b.id = w.branch_id
      WHERE w.id = ? AND w.is_active = 1 AND b.is_active = 1
    ''', [warehouseId]);
    if (rows.isEmpty) throw AppException('المخزن أو الفرع غير موجود أو غير نشط');
  }

  Future<int> _balance(Transaction txn, int productId, int warehouseId) async {
    final rows = await txn.query('product_warehouse_stock',
      columns: ['quantity'],
      where: 'product_id = ? AND warehouse_id = ?',
      whereArgs: [productId, warehouseId],
      limit: 1);
    return rows.isEmpty ? 0 : rows.single['quantity']! as int;
  }

  Future<void> _writeBalance(Transaction txn, int productId, int warehouseId, int quantity) async {
    final rows = await txn.query('product_warehouse_stock', columns: ['id'],
      where: 'product_id = ? AND warehouse_id = ?',
      whereArgs: [productId, warehouseId], limit: 1);
    final stamp = DateTime.now().toUtc().toIso8601String();
    if (rows.isEmpty) {
      await txn.insert('product_warehouse_stock', {
        'product_id': productId,
        'warehouse_id': warehouseId,
        'quantity': quantity,
        'updated_at': stamp,
      });
    } else {
      await txn.update('product_warehouse_stock', {
        'quantity': quantity,
        'updated_at': stamp,
      }, where: 'id = ?', whereArgs: [rows.single['id']]);
    }
  }

  Future<void> _writeAggregate(Transaction txn, int productId) async {
    final rows = await txn.rawQuery(
      'SELECT COALESCE(SUM(quantity), 0) AS total FROM product_warehouse_stock WHERE product_id = ?',
      [productId],
    );
    await txn.update('products', {'stock_quantity': rows.single['total']},
      where: 'id = ?', whereArgs: [productId]);
  }

  Future<void> _writeMovement(
    Transaction txn,
    int productId,
    int warehouseId,
    int delta,
    String reason, [
    String? createdAt,
  ]) async {
    await txn.insert('inventory_movements', {
      'product_id': productId,
      'warehouse_id': warehouseId,
      'quantity_delta': delta,
      'reason': reason,
      'created_at': createdAt ?? DateTime.now().toUtc().toIso8601String(),
    });
  }

  String? _optional(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
