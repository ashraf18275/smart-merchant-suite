import '../../domain/sale_record.dart';

abstract interface class SalesService {
  Future<int> createSale({
    required Map<int, int> quantities,
    required int paidMinor,
    required int warehouseId,
    int? customerId,
  });

  Future<List<SaleRecord>> all();
}
