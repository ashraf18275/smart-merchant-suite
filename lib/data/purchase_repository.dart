import 'package:sqflite_common/sqlite_api.dart';

import '../core/app_error.dart';
import 'audit_cash_writer.dart';
import '../core/quantity.dart';
import '../domain/payment_method.dart';

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

class SupplierReturnLineInput {
  const SupplierReturnLineInput({
    required this.purchaseItemId,
    required this.quantity,
  });

  final int purchaseItemId;
  /// Integer thousandths: 1000 = one unit.
  final int quantity;
}

class PurchaseRepository {
  PurchaseRepository(this._db);
  final Database _db;

  Future<List<Map<String, Object?>>> suppliers({bool includeInactive = false}) =>
      _db.query('suppliers',
        where: includeInactive ? null : 'is_active = 1',
        orderBy: 'name COLLATE NOCASE');

  Future<int> addSupplier({
    required String name,
    String? phone,
    String? address,
    int openingBalanceMinor = 0,
  }) async {
    final value = name.trim();
    if (value.isEmpty) throw AppException('اسم المورد مطلوب');
    try {
      return await _db.transaction((txn) async {
        final stamp = DateTime.now().toUtc().toIso8601String();
        final supplierId = await txn.insert('suppliers', {
          'name': value,
          'phone': _optional(phone),
          'address': _optional(address),
          'is_active': 1,
          'created_at': stamp,
        });
        if (openingBalanceMinor != 0) {
          await txn.insert('supplier_account_entries', {
            'supplier_id': supplierId,
            'amount_minor': openingBalanceMinor,
            'entry_type': 'adjustment',
            'note': 'رصيد افتتاحي عند إنشاء الحساب',
            'created_at': stamp,
          });
        }
        if (openingBalanceMinor != 0) {
          await writeAuditEvent(txn,
            action: 'supplier_opening_balance_set',
            entityType: 'supplier',
            entityId: supplierId,
            amountMinor: openingBalanceMinor,
            details: 'opening_balance_minor=' + openingBalanceMinor.toString(),
            createdAt: stamp,
          );
        }
        return supplierId;
      });
    } catch (error) {
      if (error is AppException) rethrow;
      throw AppException('تعذر حفظ المورد');
    }
  }

  Future<int> createPurchase({
    required int supplierId,
    required int warehouseId,
    required List<PurchaseLineInput> items,
    required int paidMinor,
    String paymentMethod = PaymentMethod.cash,
  }) async {
    if (items.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل');
    if (paidMinor < 0) throw AppException('المبلغ المدفوع غير صحيح');
    if (!PaymentMethod.isValid(paymentMethod)) throw AppException('طريقة الدفع المحددة غير مدعومة');

    return _db.transaction((txn) async {
      final suppliers = await txn.query('suppliers',
        columns: ['id'], where: 'id = ? AND is_active = 1',
        whereArgs: [supplierId], limit: 1);
      if (suppliers.isEmpty) throw AppException('المورد غير موجود أو موقوف');
      final warehouses = await txn.rawQuery('''
        SELECT w.id, w.branch_id FROM warehouses w JOIN branches b ON b.id = w.branch_id
        WHERE w.id = ? AND w.is_active = 1 AND b.is_active = 1 LIMIT 1
      ''', [warehouseId]);
      if (warehouses.isEmpty) throw AppException('المخزن المحدد غير موجود أو غير نشط');
      final branchId = warehouses.single['branch_id']! as int;

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
          SELECT p.cost_minor,
                 COALESCE((
                   SELECT SUM(s.quantity)
                   FROM product_warehouse_stock s
                   WHERE s.product_id = p.id
                 ), 0) AS stock_quantity,
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

      await writeAuditEvent(txn,
        action: 'purchase_created',
        entityType: 'purchase',
        entityId: purchaseId,
        amountMinor: total,
        details: 'supplier_id=$supplierId; warehouse_id=$warehouseId; paid_minor=$paidMinor',
        createdAt: stamp,
      );
      await writeCashMovement(txn,
        direction: 'out',
        category: 'purchase_payment',
        amountMinor: paidMinor,
        sourceType: 'purchase',
        sourceId: purchaseId,
        note: 'سداد عند فاتورة مشتريات رقم $purchaseId',
        createdAt: stamp,
        paymentMethod: paymentMethod,
        branchId: branchId,
      );
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


  /// Returns goods to the supplier against the original purchase. The stock,
  /// purchase-line returnable quantity and supplier ledger are updated atomically.
  Future<int> createSupplierReturn({
    required int purchaseId,
    required List<SupplierReturnLineInput> items,
    required String reason,
    int refundedMinor = 0,
    String refundMethod = PaymentMethod.cash,
  }) async {
    final cleanReason = reason.trim();
    if (items.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل للمرتجع');
    if (cleanReason.isEmpty) throw AppException('سبب المرتجع مطلوب');
    if (refundedMinor < 0) throw AppException('المبلغ المسترد لا يمكن أن يكون سالبًا');
    if (!PaymentMethod.isValid(refundMethod)) throw AppException('طريقة استرداد المبلغ غير مدعومة');
    final seen = <int>{};
    for (final item in items) {
      if (item.quantity <= 0) throw AppException('كمية المرتجع يجب أن تكون أكبر من صفر');
      if (!seen.add(item.purchaseItemId)) {
        throw AppException('لا تكرر بند الشراء في مستند المرتجع نفسه');
      }
    }

    return _db.transaction((txn) async {
      final purchases = await txn.query(
        'purchases',
        where: 'id = ?',
        whereArgs: [purchaseId],
        limit: 1,
      );
      if (purchases.isEmpty) throw AppException('فاتورة الشراء الأصلية غير موجودة');
      final purchase = purchases.single;
      final supplierId = purchase['supplier_id']! as int;
      final warehouseId = purchase['warehouse_id']! as int;
      final warehouseRows = await txn.query('warehouses', columns: ['branch_id'], where: 'id = ?', whereArgs: [warehouseId], limit: 1);
      if (warehouseRows.isEmpty) throw AppException('فرع مخزن فاتورة الشراء غير معروف');
      final branchId = warehouseRows.single['branch_id']! as int;
      final prepared = <Map<String, int>>[];
      var total = 0;

      for (final item in items) {
        final lines = await txn.rawQuery('''
          SELECT pi.id, pi.product_id, pi.quantity, pi.returned_quantity,
                 pi.unit_cost_minor, p.is_active
          FROM purchase_items pi
          JOIN products p ON p.id = pi.product_id
          WHERE pi.id = ? AND pi.purchase_id = ?
          LIMIT 1
        ''', [item.purchaseItemId, purchaseId]);
        if (lines.isEmpty) throw AppException('بند الشراء لا يتبع الفاتورة المحددة');
        final line = lines.single;
        if (line['is_active'] != 1) throw AppException('لا يمكن إرجاع منتج موقوف');
        final purchased = line['quantity']! as int;
        final returned = line['returned_quantity']! as int;
        if (item.quantity > purchased - returned) {
          throw AppException('كمية المرتجع أكبر من الكمية المتبقية من بند الشراء');
        }
        final productId = line['product_id']! as int;
        final stockRows = await txn.query(
          'product_warehouse_stock',
          columns: ['quantity'],
          where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [productId, warehouseId],
          limit: 1,
        );
        final stock = stockRows.isEmpty ? 0 : stockRows.single['quantity']! as int;
        if (stock < item.quantity) {
          throw AppException('المخزون الحالي لا يكفي لإرجاع الكمية المطلوبة للمورد');
        }
        final unitCost = line['unit_cost_minor']! as int;
        final lineTotal = Quantity.lineTotalMinor(
          unitPriceMinor: unitCost,
          quantityScaled: item.quantity,
        );
        if (lineTotal <= 0) throw AppException('قيمة بند المرتجع يجب أن تكون أكبر من صفر');
        total += lineTotal;
        prepared.add({
          'purchaseItemId': item.purchaseItemId,
          'productId': productId,
          'quantity': item.quantity,
          'stock': stock,
          'returned': returned,
          'unitCost': unitCost,
          'lineTotal': lineTotal,
        });
      }

      if (refundedMinor > total) {
        throw AppException('المبلغ المسترد من المورد لا يمكن أن يتجاوز قيمة المرتجع');
      }
      final stamp = DateTime.now().toUtc().toIso8601String();
      final returnId = await txn.insert('supplier_returns', {
        'purchase_id': purchaseId,
        'supplier_id': supplierId,
        'warehouse_id': warehouseId,
        'total_minor': total,
        'reason': cleanReason,
        'created_at': stamp,
      });

      for (final item in prepared) {
        final productId = item['productId']!;
        final quantity = item['quantity']!;
        await txn.insert('supplier_return_items', {
          'supplier_return_id': returnId,
          'purchase_item_id': item['purchaseItemId'],
          'product_id': productId,
          'quantity': quantity,
          'unit_cost_minor': item['unitCost'],
          'line_total_minor': item['lineTotal'],
        });
        await txn.update('purchase_items', {
          'returned_quantity': item['returned']! + quantity,
        }, where: 'id = ?', whereArgs: [item['purchaseItemId']]);
        await txn.update('product_warehouse_stock', {
          'quantity': item['stock']! - quantity,
          'updated_at': stamp,
        }, where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [productId, warehouseId]);
        final totals = await txn.rawQuery(
          'SELECT COALESCE(SUM(quantity), 0) AS total FROM product_warehouse_stock WHERE product_id = ?',
          [productId],
        );
        await txn.update('products', {'stock_quantity': totals.single['total']},
          where: 'id = ?', whereArgs: [productId]);
        await txn.insert('inventory_movements', {
          'product_id': productId,
          'warehouse_id': warehouseId,
          'quantity_delta': -quantity,
          'reason': 'مرتجع مشتريات رقم $returnId',
          'created_at': stamp,
        });
      }

      await writeAuditEvent(txn,
        action: 'supplier_return_created',
        entityType: 'supplier_return',
        entityId: returnId,
        amountMinor: total,
        details: 'purchase_id=$purchaseId; reason=$cleanReason',
        createdAt: stamp,
      );
      await txn.insert('supplier_account_entries', {
        'supplier_id': supplierId,
        'amount_minor': -total,
        'entry_type': 'return',
        'reference_id': returnId,
        'note': 'مرتجع مشتريات رقم $returnId — فاتورة رقم $purchaseId',
        'created_at': stamp,
      });
      if (refundedMinor > 0) {
        await txn.insert('supplier_account_entries', {
          'supplier_id': supplierId,
          'amount_minor': refundedMinor,
          'entry_type': 'adjustment',
          'reference_id': returnId,
          'note': 'استرداد من المورد عن مرتجع رقم $returnId',
          'created_at': stamp,
        });
        await writeAuditEvent(txn,
          action: 'supplier_return_refund_received',
          entityType: 'supplier_return',
          entityId: returnId,
          amountMinor: refundedMinor,
          details: 'payment_method=$refundMethod',
          createdAt: stamp,
        );
        await writeCashMovement(txn,
          direction: 'in',
          category: 'supplier_return_refund',
          amountMinor: refundedMinor,
          sourceType: 'supplier_return_refund',
          sourceId: returnId,
          note: 'استرداد من المورد عن مرتجع رقم $returnId',
          createdAt: stamp,
          paymentMethod: refundMethod,
          branchId: branchId,
        );
      }
      return returnId;
    });
  }

  /// Lists original purchase invoices that still have returnable quantities.
  Future<List<Map<String, Object?>>> supplierReturnablePurchases() =>
      _db.rawQuery('''
        SELECT pu.id, pu.created_at, pu.total_minor, s.name AS supplier_name,
               w.name AS warehouse_name
        FROM purchases pu
        JOIN suppliers s ON s.id = pu.supplier_id
        JOIN warehouses w ON w.id = pu.warehouse_id
        WHERE EXISTS (
          SELECT 1 FROM purchase_items pi
          WHERE pi.purchase_id = pu.id
            AND pi.quantity > COALESCE(pi.returned_quantity, 0)
        )
        ORDER BY pu.id DESC
      ''');

  /// Lists returnable lines and current stock in the original purchase warehouse.
  Future<List<Map<String, Object?>>> supplierReturnableItems(int purchaseId) =>
      _db.rawQuery('''
        SELECT pi.id AS purchase_item_id, pi.product_id, p.name AS product_name,
               pi.quantity, COALESCE(pi.returned_quantity, 0) AS returned_quantity,
               pi.unit_cost_minor, COALESCE(pws.quantity, 0) AS available_quantity,
               COALESCE(pu.allows_fraction, 0) AS allows_fraction,
               COALESCE(pu.abbreviation, 'وحدة') AS unit_name
        FROM purchase_items pi
        JOIN products p ON p.id = pi.product_id
        LEFT JOIN product_units pu ON pu.id = p.unit_id
        LEFT JOIN product_warehouse_stock pws
          ON pws.product_id = pi.product_id
         AND pws.warehouse_id = (
           SELECT warehouse_id FROM purchases WHERE id = ?
         )
        WHERE pi.purchase_id = ?
          AND pi.quantity > COALESCE(pi.returned_quantity, 0)
          AND p.is_active = 1
        ORDER BY pi.id ASC
      ''', [purchaseId, purchaseId]);

  String? _optional(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? null : v;
  }
}
