import 'package:sqflite_common/sqlite_api.dart';

import '../core/app_error.dart';
import '../core/quantity.dart';

class PurchaseLineInput {
  const PurchaseLineInput({
    required this.productId,
    required this.quantity,
    required this.unitCostMinor,
  });
  final int productId;
  /// Integer thousandths: 1000 = one unit.
  final int quantity;
  final int unitCostMinor;
}

class PurchaseRepository {
  PurchaseRepository(this._db);
  final Database _db;

  Future<List<Map<String, Object?>>> suppliers({bool includeInactive = false}) =>
      _db.query('suppliers',
        where: includeInactive ? null : 'is_active = 1',
        orderBy: 'name COLLATE NOCASE');

  Future<int> addSupplier({required String name, String? phone, String? address}) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم المورد مطلوب');
    try {
      return await _db.insert('suppliers', {
        'name': value,
        'phone': _optional(phone),
        'address': _optional(address),
        'is_active': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      throw AppException('تعذر حفظ المورد');
    }
  }

  Future<int> createPurchase({
    required int supplierId,
    required int warehouseId,
    required List<PurchaseLineInput> items,
    required int paidMinor,
  }) async {
    if (items.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل');
    if (paidMinor < 0) throw AppException('المبلغ المدفوع غير صحيح');

    return _db.transaction((txn) async {
      final suppliers = await txn.query('suppliers',
        columns: ['id'], where: 'id = ? AND is_active = 1',
        whereArgs: [supplierId], limit: 1);
      if (suppliers.isEmpty) throw AppException('المورد غير موجود أو موقوف');
      final warehouses = await txn.rawQuery('''
        SELECT w.id FROM warehouses w JOIN branches b ON b.id = w.branch_id
        WHERE w.id = ? AND w.is_active = 1 AND b.is_active = 1 LIMIT 1
      ''', [warehouseId]);
      if (warehouses.isEmpty) throw AppException('المخزن المحدد غير موجود أو غير نشط');

      final prepared = <Map<String, int>>[];
      final seen = <int>{};
      var total = 0;
      for (final item in items) {
        if (item.quantity <= 0 || item.unitCostMinor < 0) {
          throw AppException('راجع الكمية وتكلفة الوحدة لكل صنف');
        }
        if (!seen.add(item.productId)) {
          throw AppException('لا تكرر الصنف في مستند الشراء نفسه');
        }
        final rows = await txn.rawQuery('''
          SELECT p.cost_minor, p.stock_quantity,
                 COALESCE(u.allows_fraction, 0) AS allows_fraction
          FROM products p LEFT JOIN product_units u ON u.id = p.unit_id
          WHERE p.id = ? AND p.is_active = 1 LIMIT 1
        ''', [item.productId]);
        if (rows.isEmpty) throw AppException('أحد المنتجات غير موجود أو موقوف');
        if (rows.single['allows_fraction'] != 1 &&
            item.quantity % Quantity.scale != 0) {
          throw AppException('وحدة قياس أحد المنتجات لا تقبل الكميات الكسرية');
        }
        final lineTotal = Quantity.lineTotalMinor(
          unitPriceMinor: item.unitCostMinor,
          quantityScaled: item.quantity,
        );
        if (lineTotal <= 0) throw AppException('قيمة بند الشراء يجب أن تكون أكبر من صفر');
        total += lineTotal;
        prepared.add({
          'productId': item.productId,
          'quantity': item.quantity,
          'unitCost': item.unitCostMinor,
          'lineTotal': lineTotal,
          'oldCost': rows.single['cost_minor']! as int,
          'oldQuantity': rows.single['stock_quantity']! as int,
        });
      }
      if (paidMinor > total) throw AppException('المدفوع أكبر من إجمالي المشتريات');

      final stamp = DateTime.now().toUtc().toIso8601String();
      final purchaseId = await txn.insert('purchases', {
        'supplier_id': supplierId,
        'warehouse_id': warehouseId,
        'total_minor': total,
        'paid_minor': paidMinor,
        'created_at': stamp,
      });
      await txn.insert('supplier_account_entries', {
        'supplier_id': supplierId,
        'amount_minor': total,
        'entry_type': 'purchase',
        'reference_id': purchaseId,
        'note': 'فاتورة مشتريات رقم $purchaseId',
        'created_at': stamp,
      });
      if (paidMinor > 0) {
        await txn.insert('supplier_account_entries', {
          'supplier_id': supplierId,
          'amount_minor': -paidMinor,
          'entry_type': 'payment',
          'reference_id': purchaseId,
          'note': 'سداد عند إنشاء فاتورة مشتريات رقم $purchaseId',
          'created_at': stamp,
        });
      }

      for (final item in prepared) {
        final productId = item['productId']!;
        final quantity = item['quantity']!;
        final currentWarehouseRows = await txn.query('product_warehouse_stock',
          columns: ['quantity'],
          where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [productId, warehouseId], limit: 1);
        final warehouseQuantity = currentWarehouseRows.isEmpty
            ? 0 : currentWarehouseRows.single['quantity']! as int;
        final oldQuantity = item['oldQuantity']!;
        final newQuantity = oldQuantity + quantity;
        final weightedNumerator = oldQuantity * item['oldCost']! +
            quantity * item['unitCost']!;
        final newAverageCost = newQuantity == 0
            ? item['unitCost']!
            : (weightedNumerator + newQuantity ~/ 2) ~/ newQuantity;

        await txn.insert('purchase_items', {
          'purchase_id': purchaseId,
          'product_id': productId,
          'quantity': quantity,
          'unit_cost_minor': item['unitCost'],
          'line_total_minor': item['lineTotal'],
        });
        if (currentWarehouseRows.isEmpty) {
          await txn.insert('product_warehouse_stock', {
            'product_id': productId,
            'warehouse_id': warehouseId,
            'quantity': quantity,
            'updated_at': stamp,
          });
        } else {
          await txn.update('product_warehouse_stock', {
            'quantity': warehouseQuantity + quantity,
            'updated_at': stamp,
          }, where: 'product_id = ? AND warehouse_id = ?',
            whereArgs: [productId, warehouseId]);
        }
        final totalRows = await txn.rawQuery(
          'SELECT COALESCE(SUM(quantity), 0) AS total FROM product_warehouse_stock WHERE product_id = ?',
          [productId]);
        await txn.update('products', {
          'stock_quantity': totalRows.single['total'],
          'cost_minor': newAverageCost,
        }, where: 'id = ?', whereArgs: [productId]);
        await txn.insert('inventory_movements', {
          'product_id': productId,
          'warehouse_id': warehouseId,
          'quantity_delta': quantity,
          'reason': 'استلام مشتريات رقم $purchaseId',
          'created_at': stamp,
        });
      }
      return purchaseId;
    });
  }

  String? _optional(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? null : v;
  }
}
