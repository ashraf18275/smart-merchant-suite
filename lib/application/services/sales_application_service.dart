import '../../core/app_error.dart';
import '../../domain/sale_record.dart';
import '../../domain/sale_return_line.dart';
import '../../domain/payment_method.dart';
import '../ports/sales_service.dart';
import '../ports/sales_store.dart';

class SalesApplicationService implements SalesService {
  SalesApplicationService(this._store);

  final SalesStore _store;

  @override
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
    required int warehouseId,
    int? customerId,
    String paymentMethod = PaymentMethod.cash,
  }) async {
    if (quantities.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل');
    if (quantities.values.any((quantity) => quantity <= 0)) {
      throw AppException('كل كميات البيع يجب أن تكون أكبر من صفر');
    }
    if (paidMinor < 0) {
      throw AppException('المبلغ المدفوع لا يمكن أن يكون سالبًا');
    }
    if (!PaymentMethod.isValid(paymentMethod)) {
      throw AppException('طريقة الدفع المحددة غير مدعومة');
    }
    if (customerId != null && customerId <= 0) {
      throw AppException('العميل المحدد غير صالح');
    }
    return _store.createSale(
      quantities: quantities,
      paidMinor: paidMinor,
      warehouseId: warehouseId,
      customerId: customerId,
      paymentMethod: paymentMethod,
    );
  }

  @override
  Future<List<SaleRecord>> all() => _store.all();

  @override
  Future<int> cancelSale({
    required int saleId,
    required int refundedMinor,
    required String reason,
    String refundMethod = PaymentMethod.cash,
  }) {
    if (saleId <= 0) throw AppException('فاتورة البيع المحددة غير صالحة');
    if (refundedMinor < 0) throw AppException('المبلغ المسترد لا يمكن أن يكون سالبًا');
    if (reason.trim().isEmpty) throw AppException('سبب الإلغاء مطلوب');
    if (!PaymentMethod.isValid(refundMethod)) throw AppException('طريقة رد المبلغ غير مدعومة');
    return _store.cancelSale(
      saleId: saleId,
      refundedMinor: refundedMinor,
      reason: reason,
      refundMethod: refundMethod,
    );
  }

  @override
  Future<List<Map<String, Object?>>> returnableSales() => _store.returnableSales();

  @override
  Future<List<Map<String, Object?>>> returnableSaleItems(int saleId) {
    if (saleId <= 0) throw AppException('فاتورة البيع المحددة غير صالحة');
    return _store.returnableSaleItems(saleId);
  }

  @override
  Future<int> createCustomerReturn({
    required int saleId,
    required List<SaleReturnLineInput> items,
    required int refundedMinor,
    required String reason,
    String refundMethod = PaymentMethod.cash,
  }) {
    if (saleId <= 0) throw AppException('فاتورة البيع المحددة غير صالحة');
    if (items.isEmpty) throw AppException('أضف صنفًا واحدًا على الأقل للمرتجع');
    if (items.any((item) => item.saleItemId <= 0 || item.quantity <= 0)) {
      throw AppException('بنود المرتجع أو كمياته غير صالحة');
    }
    if (refundedMinor < 0) throw AppException('المبلغ المسترد لا يمكن أن يكون سالبًا');
    if (reason.trim().isEmpty) throw AppException('سبب المرتجع مطلوب');
    if (!PaymentMethod.isValid(refundMethod)) throw AppException('طريقة رد المبلغ غير مدعومة');
    return _store.createCustomerReturn(
      saleId: saleId,
      items: items,
      refundedMinor: refundedMinor,
      reason: reason,
      refundMethod: refundMethod,
    );
  }
}
