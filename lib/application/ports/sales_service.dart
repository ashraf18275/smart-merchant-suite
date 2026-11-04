import '../../domain/sale_record.dart';
import '../../domain/sale_return_line.dart';
import '../../domain/payment_method.dart';

abstract interface class SalesService {
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
    required int warehouseId,
    int? customerId,
    String paymentMethod = PaymentMethod.cash,
  });

  Future<List<SaleRecord>> all();

  Future<int> cancelSale({
    required int saleId,
    required int refundedMinor,
    required String reason,
  });

  Future<List<Map<String, Object?>>> returnableSales();
  Future<List<Map<String, Object?>>> returnableSaleItems(int saleId);
  Future<int> createCustomerReturn({
    required int saleId,
    required List<SaleReturnLineInput> items,
    required int refundedMinor,
    required String reason,
  });
}
