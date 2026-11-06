import 'package:sqflite_common/sqlite_api.dart';

import '../application/ports/sales_store.dart';
import 'audit_cash_writer.dart';
import '../core/app_error.dart';
import '../domain/sale_record.dart';
import '../core/quantity.dart';
import '../domain/sale_return_line.dart';
import '../domain/payment_method.dart';
import 'sync_outbox_repository.dart';

class SalesRepository implements SalesStore {
  SalesRepository(this._db);
  final Database _db;

  /// Creates a multi-item invoice, updates stock and writes account/audit rows
  /// atomically. Quantities are positive integer thousandths.
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
    required int warehouseId,
    int? customerId,
    String paymentMethod = PaymentMethod.cash,
  }) async {
    // Keep core invariants enforced at the persistence boundary as well as
    // in the application service; repositories may be called by other flows.
    if (quantities.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل');
    if (quantities.values.any((quantity) => quantity <= 0)) {
      throw AppException('كمية البيع يجب أن تكون أكبر من صفر');
    }
    if (paidMinor < 0) throw AppException('المبلغ المدفوع لا يمكن أن يكون سالبًا');
    if (!PaymentMethod.isValid(paymentMethod)) throw AppException('طريقة الدفع المحددة غير مدعومة');

    return _db.transaction((txn) async {
      if (customerId != null) {
        final customers = await txn.query(
          'customers',
          columns: ['id'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [customerId],
          limit: 1,
        );
        if (customers.isEmpty) {
          throw AppException('العميل المحدد غير موجود أو غير نشط');
        }
      }
      final selectedWarehouses = await txn.rawQuery("""
        SELECT w.id, w.branch_id FROM warehouses w
        JOIN branches b ON b.id = w.branch_id
        WHERE w.id = ? AND w.is_active = 1 AND b.is_active = 1
        LIMIT 1
      """, [warehouseId]);
      if (selectedWarehouses.isEmpty) {
        throw AppException('المخزن المحدد أو الفرع التابع له غير موجود أو غير نشط');
      }
      final branchId = selectedWarehouses.single['branch_id']! as int;
      final cloudIdentity = await txn.query(
        'sync_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['database_business_id'],
        limit: 1,
      );
      final isCloudBusiness = cloudIdentity.isNotEmpty;
      int? cashDrawerId;
      int? cashSessionId;
      if (isCloudBusiness && paidMinor > 0 && paymentMethod == PaymentMethod.cash) {
        final drawer = await ensureCashDrawerForCurrentDevice(
          txn,
          branchId: branchId,
        );
        cashDrawerId = drawer['id']! as int;
        final sessions = await txn.query(
          'cash_sessions',
          columns: ['id'],
          where: "branch_id = ? AND cash_drawer_id = ? AND status = 'open'",
          whereArgs: [branchId, cashDrawerId],
          limit: 1,
        );
        if (sessions.isEmpty) {
          throw AppException('افتح وردية الصندوق لهذا الجهاز قبل مزامنة تحصيل البيع النقدي');
        }
        cashSessionId = sessions.single['id']! as int;
      }
      final items = <Map<String, int>>[];
      var total = 0;
      for (final entry in quantities.entries) {
        final rows = await txn.rawQuery('''
          SELECT p.cost_minor, p.price_minor,
                 COALESCE(u.allows_fraction, 0) AS allows_fraction
          FROM products p LEFT JOIN product_units u ON u.id = p.unit_id
          WHERE p.id = ? AND p.is_active = 1 LIMIT 1
        ''', [entry.key]);
        if (entry.value <= 0) throw AppException('كمية البيع يجب أن تكون أكبر من صفر');
        if (rows.isEmpty) throw AppException('أحد المنتجات غير موجود أو غير نشط');
        if (rows.single['allows_fraction'] != 1 && entry.value % Quantity.scale != 0) {
          throw AppException('وحدة قياس أحد المنتجات لا تقبل الكميات الكسرية');
        }
        final balances = await txn.query(
          'product_warehouse_stock',
          columns: ['quantity'],
          where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [entry.key, warehouseId],
          limit: 1,
        );
        final stock = balances.isEmpty ? 0 : balances.single['quantity']! as int;
        final product = rows.single;
        if (stock < entry.value) throw AppException('الكمية غير كافية لأحد المنتجات.');
        final price = product['price_minor']! as int;
        final cost = product['cost_minor']! as int;
        final lineTotal = Quantity.lineTotalMinor(
          unitPriceMinor: price,
          quantityScaled: entry.value,
        );
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
      if (paidMinor < total && customerId == null) {
        throw AppException('حدد العميل عند ترك أي مبلغ آجل من الفاتورة');
      }

      final createdAt = DateTime.now().toUtc().toIso8601String();
      final saleId = await txn.insert('sales', {
        'total_minor': total,
        'paid_minor': paidMinor,
        'warehouse_id': warehouseId,
        'customer_id': customerId,
        'created_at': createdAt,
      });
      if (customerId != null) {
        await txn.insert('customer_account_entries', {
          'customer_id': customerId,
          'amount_minor': total,
          'entry_type': 'sale',
          'reference_id': saleId,
          'note': 'فاتورة بيع رقم $saleId',
          'created_at': createdAt,
        });
        if (paidMinor > 0) {
          await txn.insert('customer_account_entries', {
            'customer_id': customerId,
            'amount_minor': -paidMinor,
            'entry_type': 'receipt',
            'reference_id': saleId,
            'note': 'تحصيل عند إنشاء فاتورة البيع رقم $saleId',
            'created_at': createdAt,
          });
        }
      }
      await writeAuditEvent(txn,
        action: 'sale_created',
        entityType: 'sale',
        entityId: saleId,
        amountMinor: total,
        details: 'warehouse_id=$warehouseId; customer_id=${customerId ?? ''}',
        createdAt: createdAt,
      );
      await writeCashMovement(txn,
        direction: 'in',
        category: 'sale_receipt',
        amountMinor: paidMinor,
        sourceType: 'sale',
        sourceId: saleId,
        note: 'تحصيل لفاتورة بيع رقم $saleId',
        createdAt: createdAt,
        paymentMethod: paymentMethod,
        branchId: branchId,
        cashSessionId: cashSessionId,
        cashDrawerId: cashDrawerId,
      );
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
        await txn.update('product_warehouse_stock', {
          'quantity': item['stock']! - quantity,
          'updated_at': createdAt,
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
          'reason': 'بيع فاتورة رقم $saleId',
          'created_at': createdAt,
        });
      }

      final outbox = SyncOutboxRepository(_db);
      final dependencies = [...await outbox.latestUnfinishedEventIdsForCurrentBusiness(
        executor: txn,
        entityType: 'product',
        localEntityIds: quantities.keys.map((id) => id.toString()).toList(),
      )];
      if (cashSessionId != null) {
        final sessionDependency = await outbox.latestUnfinishedEventIdForCurrentBusiness(
          executor: txn,
          entityType: 'cash_session',
          localEntityId: cashSessionId.toString(),
        );
        if (sessionDependency != null) dependencies.add(sessionDependency);
      }
      await outbox.enqueueForCurrentBusiness(
        executor: txn,
        entityType: 'sale',
        localEntityId: saleId.toString(),
        action: 'create',
        payload: {
          'payload_schema_version': 1,
          'local_branch_id': branchId,
          'local_warehouse_id': warehouseId,
          'local_customer_id': customerId,
          'paid_minor': paidMinor,
          'payment_method': paymentMethod,
          'local_cash_session_id': cashSessionId,
          'items': items.map((item) => {
            'local_product_id': item['productId'],
            'quantity_scaled': item['quantity'],
            'unit_price_minor': item['price'],
            'unit_cost_minor': item['cost'],
          }).toList(),
        },
        dependsOnEventIds: dependencies,
      );
      return saleId;
    });
  }


  Future<List<Map<String, Object?>>> returnableSales() => _db.rawQuery('''
    SELECT s.id, s.customer_id, s.total_minor, s.created_at,
           c.name AS customer_name, w.name AS warehouse_name,
           COUNT(i.id) AS item_count
    FROM sales s
    LEFT JOIN customers c ON c.id = s.customer_id
    JOIN warehouses w ON w.id = s.warehouse_id
    JOIN sale_items i ON i.sale_id = s.id
    WHERE i.quantity > COALESCE(i.returned_quantity, 0)
      AND s.cancelled_at IS NULL
    GROUP BY s.id, c.name, w.name
    ORDER BY s.id DESC
  ''');

  Future<List<Map<String, Object?>>> returnableSaleItems(int saleId) =>
      _db.rawQuery('''
        SELECT i.id AS sale_item_id, i.product_id, p.name AS product_name,
               i.quantity, COALESCE(i.returned_quantity, 0) AS returned_quantity,
               i.quantity - COALESCE(i.returned_quantity, 0) AS remaining_quantity,
               i.unit_price_minor, i.line_total_minor,
               COALESCE(i.returned_minor, 0) AS returned_minor,
               COALESCE(u.name, 'وحدة') AS unit_name,
               COALESCE(u.allows_fraction, 0) AS allows_fraction
        FROM sale_items i
        JOIN sales s ON s.id = i.sale_id
        JOIN products p ON p.id = i.product_id
        LEFT JOIN product_units u ON u.id = p.unit_id
        WHERE i.sale_id = ?
          AND i.quantity > COALESCE(i.returned_quantity, 0)
          AND s.cancelled_at IS NULL
          AND s.warehouse_id IS NOT NULL
        ORDER BY i.id ASC
      ''', [saleId]);

  Future<int> createCustomerReturn({
    required int saleId,
    required List<SaleReturnLineInput> items,
    required int refundedMinor,
    required String reason,
    String refundMethod = PaymentMethod.cash,
  }) async {
    if (saleId <= 0) throw AppException('فاتورة البيع المحددة غير صالحة');
    if (items.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل للمرتجع');
    if (items.any((item) => item.saleItemId <= 0 || item.quantity <= 0)) {
      throw AppException('بنود المرتجع أو كمياته غير صالحة');
    }
    if (refundedMinor < 0) throw AppException('المبلغ المسترد لا يمكن أن يكون سالبًا');
    if (!PaymentMethod.isValid(refundMethod)) throw AppException('طريقة رد المبلغ غير مدعومة');
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty) throw AppException('سبب المرتجع مطلوب');
    if (items.map((item) => item.saleItemId).toSet().length != items.length) {
      throw AppException('لا يمكن تكرار الصنف نفسه في بنود المرتجع');
    }

    return _db.transaction((txn) async {
      final sales = await txn.query('sales',
        columns: ['id', 'customer_id', 'warehouse_id', 'cancelled_at'],
        where: 'id = ?', whereArgs: [saleId], limit: 1);
      if (sales.isEmpty) throw AppException('فاتورة البيع غير موجودة');
      final sale = sales.single;
      if (sale['cancelled_at'] != null) {
        throw AppException('لا يمكن تسجيل مرتجع على فاتورة ملغاة');
      }
      final warehouseId = sale['warehouse_id'] as int?;
      if (warehouseId == null) {
        throw AppException('لا يمكن إرجاع فاتورة قديمة لا يحتوي سجلها على مخزن محدد');
      }
      final warehouseRows = await txn.query('warehouses', columns: ['branch_id'], where: 'id = ?', whereArgs: [warehouseId], limit: 1);
      if (warehouseRows.isEmpty) throw AppException('فرع مخزن الفاتورة غير معروف');
      final branchId = warehouseRows.single['branch_id']! as int;
      final customerId = sale['customer_id'] as int?;
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final prepared = <Map<String, int>>[];
      var totalMinor = 0;

      for (final input in items) {
        final rows = await txn.rawQuery('''
          SELECT i.product_id, i.quantity, i.unit_price_minor, i.unit_cost_minor,
                 i.line_total_minor, p.cost_minor AS current_cost_minor,
                 p.stock_quantity AS current_stock_quantity,
                 COALESCE(i.returned_quantity, 0) AS returned_quantity,
                 COALESCE(i.returned_minor, 0) AS returned_minor,
                 COALESCE(i.returned_cost_minor, 0) AS returned_cost_minor,
                 COALESCE(u.allows_fraction, 0) AS allows_fraction
          FROM sale_items i
          JOIN products p ON p.id = i.product_id
          LEFT JOIN product_units u ON u.id = p.unit_id
          WHERE i.id = ? AND i.sale_id = ? LIMIT 1
        ''', [input.saleItemId, saleId]);
        if (rows.isEmpty) throw AppException('أحد الأصناف لا ينتمي إلى فاتورة البيع المحددة');
        final line = rows.single;
        final soldQuantity = line['quantity']! as int;
        final alreadyReturned = line['returned_quantity']! as int;
        final remainingQuantity = soldQuantity - alreadyReturned;
        if (input.quantity > remainingQuantity) {
          throw AppException('كمية المرتجع أكبر من الكمية المتبقية من الصنف المباع');
        }
        if (line['allows_fraction'] != 1 && input.quantity % Quantity.scale != 0) {
          throw AppException('وحدة قياس أحد الأصناف لا تقبل الكميات الكسرية');
        }
        final unitPrice = line['unit_price_minor']! as int;
        final unitCost = line['unit_cost_minor']! as int;
        final remainingCost = Quantity.lineTotalMinor(
          unitPriceMinor: unitCost,
          quantityScaled: soldQuantity,
        ) - (line['returned_cost_minor']! as int);
        final returnCost = input.quantity == remainingQuantity
            ? remainingCost
            : Quantity.lineTotalMinor(
                unitPriceMinor: unitCost,
                quantityScaled: input.quantity,
              ).clamp(0, remainingCost).toInt();
        final remainingValue = (line['line_total_minor']! as int) -
            (line['returned_minor']! as int);
        final lineValue = input.quantity == remainingQuantity
            ? remainingValue
            : Quantity.lineTotalMinor(unitPriceMinor: unitPrice,
                quantityScaled: input.quantity).clamp(0, remainingValue).toInt();
        final balances = await txn.query('product_warehouse_stock',
          columns: ['quantity'], where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [line['product_id'], warehouseId], limit: 1);
        final stock = balances.isEmpty ? 0 : balances.single['quantity']! as int;
        prepared.add({
          'saleItemId': input.saleItemId,
          'productId': line['product_id']! as int,
          'quantity': input.quantity,
          'newReturnedQuantity': alreadyReturned + input.quantity,
          'newReturnedMinor': (line['returned_minor']! as int) + lineValue,
          'newReturnedCostMinor': (line['returned_cost_minor']! as int) + returnCost,
          'unitPrice': unitPrice,
          'unitCost': unitCost,
          'lineCost': returnCost,
          'currentCost': line['current_cost_minor']! as int,
          'currentStock': line['current_stock_quantity']! as int,
          'lineTotal': lineValue,
          'stock': stock,
        });
        totalMinor += lineValue;
      }
      if (refundedMinor > totalMinor) {
        throw AppException('المبلغ المسترد نقدًا لا يمكن أن يتجاوز قيمة البضاعة المرتجعة');
      }

      final returnId = await txn.insert('customer_returns', {
        'sale_id': saleId, 'customer_id': customerId,
        'warehouse_id': warehouseId, 'total_minor': totalMinor,
        'refunded_minor': refundedMinor, 'reason': cleanReason,
        'created_at': createdAt,
      });
      for (final line in prepared) {
        await txn.insert('customer_return_items', {
          'customer_return_id': returnId,
          'sale_item_id': line['saleItemId'],
          'product_id': line['productId'],
          'quantity': line['quantity'],
          'unit_price_minor': line['unitPrice'],
          'unit_cost_minor': line['unitCost'],
          'line_total_minor': line['lineTotal'],
          'line_cost_minor': line['lineCost'],
        });
        await txn.update('sale_items', {
          'returned_quantity': line['newReturnedQuantity'],
          'returned_minor': line['newReturnedMinor'],
          'returned_cost_minor': line['newReturnedCostMinor'],
        }, where: 'id = ?', whereArgs: [line['saleItemId']]);

        final newStock = line['stock']! + line['quantity']!;
        final existing = await txn.query('product_warehouse_stock',
          columns: ['id'], where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [line['productId'], warehouseId], limit: 1);
        if (existing.isEmpty) {
          await txn.insert('product_warehouse_stock', {
            'product_id': line['productId'], 'warehouse_id': warehouseId,
            'quantity': newStock, 'updated_at': createdAt,
          });
        } else {
          await txn.update('product_warehouse_stock', {
            'quantity': newStock, 'updated_at': createdAt,
          }, where: 'product_id = ? AND warehouse_id = ?',
            whereArgs: [line['productId'], warehouseId]);
        }
        final totals = await txn.rawQuery(
          'SELECT COALESCE(SUM(quantity), 0) AS total FROM product_warehouse_stock WHERE product_id = ?',
          [line['productId']]);
        final newTotalQuantity = line['currentStock']! + line['quantity']!;
        final weightedNumerator = line['currentStock']! * line['currentCost']! +
            line['quantity']! * line['unitCost']!;
        final newAverageCost = newTotalQuantity == 0
            ? line['unitCost']!
            : (weightedNumerator + newTotalQuantity ~/ 2) ~/ newTotalQuantity;
        await txn.update('products', {
          'stock_quantity': totals.single['total'],
          'cost_minor': newAverageCost,
        }, where: 'id = ?', whereArgs: [line['productId']]);
        await txn.insert('inventory_movements', {
          'product_id': line['productId'], 'warehouse_id': warehouseId,
          'quantity_delta': line['quantity'],
          'reason': 'مرتجع بيع فاتورة رقم $saleId',
          'created_at': createdAt,
        });
      }
      await writeAuditEvent(txn,
        action: 'customer_return_created',
        entityType: 'customer_return',
        entityId: returnId,
        amountMinor: totalMinor,
        details: 'sale_id=$saleId; refunded_minor=$refundedMinor; reason=$cleanReason',
        createdAt: createdAt,
      );
      await writeCashMovement(txn,
        direction: 'out',
        category: 'customer_return_refund',
        amountMinor: refundedMinor,
        sourceType: 'customer_return',
        sourceId: returnId,
        note: 'رد مبلغ عن مرتجع فاتورة رقم $saleId',
        createdAt: createdAt,
        paymentMethod: refundMethod,
        branchId: branchId,
      );
      if (customerId != null && totalMinor > 0) {
        await txn.insert('customer_account_entries', {
          'customer_id': customerId, 'amount_minor': -totalMinor,
          'entry_type': 'return', 'reference_id': returnId,
          'note': 'مرتجع فاتورة البيع رقم $saleId', 'created_at': createdAt,
        });
        if (refundedMinor > 0) {
          await txn.insert('customer_account_entries', {
            'customer_id': customerId, 'amount_minor': refundedMinor,
            'entry_type': 'refund', 'reference_id': returnId,
            'note': 'مبلغ نقدي مسترد عن مرتجع فاتورة البيع رقم $saleId',
            'created_at': createdAt,
          });
        }
      }
      return returnId;
    });
  }


  /// Cancels an untouched invoice, restoring its original stock and reversing
  /// its customer ledger entries in one transaction. Any existing return blocks
  /// cancellation to avoid double reversal.
  Future<int> cancelSale({
    required int saleId,
    required int refundedMinor,
    required String reason,
    String refundMethod = PaymentMethod.cash,
  }) async {
    if (saleId <= 0) throw AppException('فاتورة البيع المحددة غير صالحة');
    if (refundedMinor < 0) throw AppException('المبلغ المسترد لا يمكن أن يكون سالبًا');
    if (!PaymentMethod.isValid(refundMethod)) throw AppException('طريقة رد المبلغ غير مدعومة');
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty) throw AppException('سبب الإلغاء مطلوب');

    return _db.transaction((txn) async {
      final sales = await txn.query('sales',
        where: 'id = ?', whereArgs: [saleId], limit: 1);
      if (sales.isEmpty) throw AppException('فاتورة البيع غير موجودة');
      final sale = sales.single;
      if (sale['cancelled_at'] != null) {
        throw AppException('تم إلغاء هذه الفاتورة من قبل');
      }
      final priorReturns = await txn.query('customer_returns',
        columns: ['id'], where: 'sale_id = ?', whereArgs: [saleId], limit: 1);
      if (priorReturns.isNotEmpty) {
        throw AppException('لا يمكن إلغاء فاتورة لها مرتجعات مسجلة؛ راجع حركة المرتجعات أولًا');
      }

      final totalMinor = sale['total_minor']! as int;
      final paidMinor = sale['paid_minor']! as int;
      if (refundedMinor > paidMinor) {
        throw AppException('المبلغ المسترد نقدًا لا يمكن أن يتجاوز ما تم تحصيله في الفاتورة');
      }
      final warehouseId = sale['warehouse_id'] as int?;
      if (warehouseId == null) {
        throw AppException('لا يمكن إلغاء فاتورة قديمة لا يحتوي سجلها على مخزن محدد');
      }
      final warehouseRows = await txn.query('warehouses', columns: ['branch_id'], where: 'id = ?', whereArgs: [warehouseId], limit: 1);
      if (warehouseRows.isEmpty) throw AppException('فرع مخزن الفاتورة غير معروف');
      final branchId = warehouseRows.single['branch_id']! as int;
      final customerId = sale['customer_id'] as int?;
      final lines = await txn.query('sale_items',
        where: 'sale_id = ?', whereArgs: [saleId], orderBy: 'id ASC');
      if (lines.isEmpty) throw AppException('لا يمكن إلغاء فاتورة بلا بنود');

      final createdAt = DateTime.now().toUtc().toIso8601String();
      final cancellationId = await txn.insert('sales_cancellations', {
        'sale_id': saleId,
        'customer_id': customerId,
        'warehouse_id': warehouseId,
        'total_minor': totalMinor,
        'paid_minor': paidMinor,
        'refunded_minor': refundedMinor,
        'reason': cleanReason,
        'created_at': createdAt,
      });

      for (final line in lines) {
        final productId = line['product_id']! as int;
        final quantity = line['quantity']! as int;
        final unitCost = line['unit_cost_minor']! as int;
        final balances = await txn.query('product_warehouse_stock',
          columns: ['quantity'],
          where: 'product_id = ? AND warehouse_id = ?',
          whereArgs: [productId, warehouseId], limit: 1);
        final oldWarehouseStock = balances.isEmpty
            ? 0
            : balances.single['quantity']! as int;
        final productRows = await txn.query('products',
          columns: ['stock_quantity', 'cost_minor'],
          where: 'id = ?', whereArgs: [productId], limit: 1);
        if (productRows.isEmpty) {
          throw AppException('أحد منتجات الفاتورة لم يعد موجودًا؛ لم يتم إلغاء الفاتورة');
        }
        final oldTotalStock = productRows.single['stock_quantity']! as int;
        final oldAverageCost = productRows.single['cost_minor']! as int;
        final newWarehouseStock = oldWarehouseStock + quantity;
        final newTotalStock = oldTotalStock + quantity;
        final weightedNumerator = oldTotalStock * oldAverageCost +
            quantity * unitCost;
        final newAverageCost = newTotalStock == 0
            ? unitCost
            : (weightedNumerator + newTotalStock ~/ 2) ~/ newTotalStock;

        if (balances.isEmpty) {
          await txn.insert('product_warehouse_stock', {
            'product_id': productId,
            'warehouse_id': warehouseId,
            'quantity': newWarehouseStock,
            'updated_at': createdAt,
          });
        } else {
          await txn.update('product_warehouse_stock', {
            'quantity': newWarehouseStock,
            'updated_at': createdAt,
          }, where: 'product_id = ? AND warehouse_id = ?',
            whereArgs: [productId, warehouseId]);
        }
        final aggregate = await txn.rawQuery(
          'SELECT COALESCE(SUM(quantity), 0) AS total FROM product_warehouse_stock WHERE product_id = ?',
          [productId],
        );
        await txn.update('products', {
          'stock_quantity': aggregate.single['total'],
          'cost_minor': newAverageCost,
        }, where: 'id = ?', whereArgs: [productId]);
        await txn.insert('inventory_movements', {
          'product_id': productId,
          'warehouse_id': warehouseId,
          'quantity_delta': quantity,
          'reason': 'إلغاء فاتورة بيع رقم $saleId',
          'created_at': createdAt,
        });
      }

      if (customerId != null) {
        await txn.insert('customer_account_entries', {
          'customer_id': customerId,
          'amount_minor': -totalMinor,
          'entry_type': 'sale_cancel',
          'reference_id': cancellationId,
          'note': 'عكس فاتورة البيع الملغاة رقم $saleId',
          'created_at': createdAt,
        });
        if (paidMinor > 0) {
          await txn.insert('customer_account_entries', {
            'customer_id': customerId,
            'amount_minor': paidMinor,
            'entry_type': 'receipt_reversal',
            'reference_id': cancellationId,
            'note': 'عكس تحصيل فاتورة البيع الملغاة رقم $saleId',
            'created_at': createdAt,
          });
        }
        final refundDue = paidMinor - refundedMinor;
        if (refundDue > 0) {
          await txn.insert('customer_account_entries', {
            'customer_id': customerId,
            'amount_minor': -refundDue,
            'entry_type': 'refund_due',
            'reference_id': cancellationId,
            'note': 'مبلغ مستحق رده للعميل عن إلغاء فاتورة رقم $saleId',
            'created_at': createdAt,
          });
        }
      }

      await writeAuditEvent(txn,
        action: 'sale_cancelled',
        entityType: 'sale_cancellation',
        entityId: cancellationId,
        amountMinor: totalMinor,
        details: 'sale_id=$saleId; refunded_minor=$refundedMinor; reason=$cleanReason',
        createdAt: createdAt,
      );
      await writeCashMovement(txn,
        direction: 'out',
        category: 'sale_cancellation_refund',
        amountMinor: refundedMinor,
        sourceType: 'sale_cancellation',
        sourceId: cancellationId,
        note: 'رد مبلغ عن إلغاء فاتورة رقم $saleId',
        createdAt: createdAt,
        paymentMethod: refundMethod,
        branchId: branchId,
      );
      await txn.update('sales', {
        'cancelled_at': createdAt,
        'cancellation_reason': cleanReason,
      }, where: 'id = ?', whereArgs: [saleId]);
      return cancellationId;
    });
  }

  Future<List<SaleRecord>> all() async {
    final rows = await _db.rawQuery('''
      SELECT s.id, s.total_minor, s.paid_minor, s.created_at,
             s.cancelled_at, s.cancellation_reason,
             COUNT(i.id) AS item_count,
             w.name AS warehouse_name, b.name AS branch_name
      FROM sales s
      LEFT JOIN sale_items i ON i.sale_id = s.id
      LEFT JOIN warehouses w ON w.id = s.warehouse_id
      LEFT JOIN branches b ON b.id = w.branch_id
      GROUP BY s.id, w.name, b.name
      ORDER BY s.id DESC
    ''');
    return rows.map((row) => SaleRecord(
      id: row['id']! as int,
      totalMinor: row['total_minor']! as int,
      paidMinor: row['paid_minor']! as int,
      createdAt: DateTime.parse(row['created_at']! as String).toLocal(),
      itemCount: row['item_count']! as int,
      cancelledAt: row['cancelled_at'] == null
          ? null : DateTime.parse(row['cancelled_at']! as String).toLocal(),
      cancellationReason: row['cancellation_reason'] as String?,
      warehouseName: row['warehouse_name'] as String?,
      branchName: row['branch_name'] as String?,
    )).toList(growable: false);
  }
}
